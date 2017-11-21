classdef SIBT < scanner
%% SIBT
% BakingTray does not call ScanImage directly but goes through this glue
% object that inherits the abstract class, scanner. The SIBT concrete class 
% as a glue or bridge between ScanImage and BakingTray. This class 
% implements all the methods needed to trigger image acquisition, set the 
% power at the sample, and save images, etc. The reason for doing this is
% to provide the possibility of using a different piece of acquisition 
% software without changing any of the methods in the core BakingTray
% class or any of the GUIs. It also makes it possible to create a dummy
% scanner that serves up previously acquired data. This can be used to 
% prototype different acquisition scenarios requiring a live acquisition
% to be taking place. 
%
%
% This version of the class is written against ScanImage 5.2 (2016)
%
% TODO: what does  hSI.hScan2D.scannerToRefTransform do?

    properties
        % If true you get debug messages printed during scanning and when listener callbacks are hit
        verbose=false;
    end

    properties (Hidden)
        defaultShutterIDs %The default shutter IDs used by the scanner
        maxStripe=1; %Number of channel window updates per second
        listeners={}
        armedListeners={} %These listeners are enabled only when the scanner is "armed" for acquisition
        currentTilePattern
    end

    methods

        %constructor
        function obj=SIBT(API)
            if nargin<1
                API=[];
            end
            obj.connect(API);
            obj.scannerID='ScanImage via SIBT';
        end %constructor


        %destructor
        function delete(obj)
            cellfun(@delete,obj.listeners)
            cellfun(@delete,obj.armedListeners)
            obj.hC=[];
        end %destructor


        % - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
        function success = connect(obj,API)
            %TODO: why the hell isn't this in the constructor?
            success=false;

            if nargin<2 || isempty(API)
                scanimageObjectName='hSI';
                W = evalin('base','whos');
                SIexists = ismember(scanimageObjectName,{W.name});
                if ~SIexists
                    obj.logMessage(inputname(1),dbstack,7,'ScanImage not started. Can not connect to scanner.')
                    return
                end

                API = evalin('base',scanimageObjectName); % get hSI from the base workspace
            end

            if ~isa(API,'scanimage.SI')
                obj.logMessage(inputname(1) ,dbstack,7,'hSI is not a ScanImage object.')
                return
            end

            obj.hC=API;

            fprintf('\n\nStarting SIBT interface for ScanImage\n')
            %Log default state of settings so we return to these when disarming
            obj.defaultShutterIDs = obj.hC.hScan2D.mdfData.shutterIDs;


            % Add ScanImage-specific listeners

            obj.channelsToAcquire; %Stores the currently selected channels to save in an observable property
            % Update channels to save property whenever the user makes changes in scanImage
            obj.listeners{end+1} = addlistener(obj.hC.hChannels,'channelSave', 'PostSet', @obj.channelsToAcquire);
            obj.listeners{end+1} = addlistener(obj.hC.hChannels,'channelDisplay', 'PostSet', @obj.flipScanSettingsChanged);

            obj.listeners{end+1} = addlistener(obj.hC, 'active', 'PostSet', @obj.isAcquiring);

            % obj.enforceImportantSettings
            %Set listeners on properties we don't want the user to change. Hitting any of these
            %will call a single method that resets all of the properties to the values we desire. 
            obj.listeners{end+1} = addlistener(obj.hC.hRoiManager, 'forceSquarePixels', 'PostSet', @obj.enforceImportantSettings);

            obj.LUTchanged
            obj.listeners{end+1}=addlistener(obj.hC.hDisplay,'chan1LUT', 'PostSet', @obj.LUTchanged);
            obj.listeners{end+1}=addlistener(obj.hC.hDisplay,'chan2LUT', 'PostSet', @obj.LUTchanged);
            obj.listeners{end+1}=addlistener(obj.hC.hDisplay,'chan3LUT', 'PostSet', @obj.LUTchanged);
            obj.listeners{end+1}=addlistener(obj.hC.hDisplay,'chan4LUT', 'PostSet', @obj.LUTchanged);


            obj.listeners{end+1}=addlistener(obj.hC.hRoiManager, 'scanZoomFactor', 'PostSet', @obj.flipScanSettingsChanged);
            obj.listeners{end+1}=addlistener(obj.hC.hRoiManager, 'scanFrameRate',  'PostSet', @obj.flipScanSettingsChanged);


            % Add "armedListeners" that are used during tiled acquisition only.
            obj.armedListeners{end+1}=addlistener(obj.hC.hUserFunctions, 'acqDone', @obj.tileAcqDone);
            obj.armedListeners{end+1}=addlistener(obj.hC.hUserFunctions, 'acqAbort', @obj.tileScanAbortedInScanImage);
            obj.disableArmedListeners % Because we only want them active when we start tile scanning

            if isfield(obj.hC.hScan2D.mdfData,'stripingMaxRate') &&  obj.hC.hScan2D.mdfData.stripingMaxRate>obj.maxStripe
                %The number of channel window updates per second
                fprintf('Restricting display stripe rate to %d Hz. This can speed up acquisition.\n',obj.maxStripe)
                obj.hC.hScan2D.mdfData.stripingMaxRate=obj.maxStripe;
            end

            obj.enforceImportantSettings
            success=true;
        end %connect


        function ready = isReady(obj)
            if isempty(obj.hC)
                ready=false;
                return
            end
            ready=strcmpi(obj.hC.acqState,'idle');
        end %isReady


        function [success,msg] = armScanner(obj)
            %Arm scanner and tell it to acquire a fixed number of frames (as defined below)
            success=false;
            if isempty(obj.parent) || ~obj.parent.isRecipeConnected
                obj.logMessage(inputname(1) ,dbstack,7,'SIBT is not attached to a BT object with a recipe')
                return
            end

            % We'll need to enable external triggering on the correct terminal line. 
            % Safest to instruct ScanImage of this each time. 
            switch obj.scannerType
                case 'resonant'
                    %To make it possible to enable the external trigger. PFI0 is reserved for resonant scanning
                    obj.hC.hScan2D.trigAcqInTerm='PFI1';
                case 'linear'
                    obj.hC.hScan2D.trigAcqInTerm='PFI0';
            end


            obj.enableArmedListeners

            % The string "msg" will contain any messages we wish to display to the user as part of the confirmation box.
            msg = '';

            obj.hC.hChannels.channelSubtractOffset(:)=0;   % Disable offset subtraction
            % Ensure the offset is auto-read so we can use this value later
            obj.hC.hScan2D.channelsAutoReadOffsets=true;

            msg = sprintf('%sDisabled offset subtraction.\n',msg);
            obj.hC.hDisplay.displayRollingAverageFactor=1; % We don't want to take rolling averages


            obj.applyZstackSettingsFromRecipe % Prepare ScanImage for doing z-stacks

            % Set the system to display just the first depth in ScanImage. 
            % Should run a little faster this way, especially if we have 
            % multiple channels being displayed.
            if obj.hC.hStackManager.numSlices>1 && isempty(obj.hC.hDisplay.selectedZs)
            fprintf('Displaying only first depth in ScanImage for speed reasons.\n');
                obj.hC.hDisplay.volumeDisplayStyle='Current';
                obj.hC.hDisplay.selectedZs=0;
            end

            %If any of these fail, we leave the function gracefully
            try
                obj.hC.acqsPerLoop=obj.parent.recipe.numTilesInOpticalSection;% This is the number of x/y positions that need to be visited
                obj.hC.extTrigEnable=1;
                %Put it into acquisition mode but it won't proceed because it's waiting for a trigger
                obj.hC.startLoop;
            catch ME1
                rethrow(ME1)
                return
            end

            success=true;

            obj.hC.hScan2D.mdfData.shutterIDs=[]; %Disable shutters

            % Store the current tile pattern, as it's generated on the fly and 
            % and this is time-consuming to put into the tile acq callback. 
            obj.currentTilePattern=obj.parent.recipe.tilePattern;

            fprintf('Armed scanner: %s\n', datestr(now))
        end %armScanner


        function applyZstackSettingsFromRecipe(obj)
            % applyZstackSettingsFromRecipe
            % This method is (at least for now) specific to ScanImage. 
            % Its main purpose is to set the number of planes and distance between planes.
            % It also sets the the view style to tiled. This method is called by armScanner
            % but also by external classes at certain times in order to set up the correct 
            % Z settings in ScanImage so the user can do a quick Grab and check the
            % illumination correction with depth.

            thisRecipe = obj.parent.recipe;
            if thisRecipe.mosaic.numOpticalPlanes>1
                fprintf('Setting up z-scanning with "step" waveform\n')

                % Only change settings that need changing, otherwise it's slow.
                % The following settings are fixed: they will never change
                if ~strcmp(obj.hC.hFastZ.waveformType,'step') 
                    obj.hC.hFastZ.waveformType = 'step'; %Always
                end
                if obj.hC.hFastZ.numVolumes ~= 1
                    obj.hC.hFastZ.numVolumes=1; %Always
                end
                if obj.hC.hFastZ.enable ~=1
                    obj.hC.hFastZ.enable=1;
                end
                if obj.hC.hStackManager.framesPerSlice ~= 1
                    obj.hC.hStackManager.framesPerSlice = 1; %Always (number of frames per grab per layer)
                end
                if obj.hC.hStackManager.stackReturnHome ~= 1
                    obj.hC.hStackManager.stackReturnHome = 1;
                end

                % Now set the number of slices and the distance in z over which to image
                sliceThicknessInUM = thisRecipe.mosaic.sliceThickness*1E3;

                if obj.hC.hStackManager.numSlices ~= thisRecipe.mosaic.numOpticalPlanes;
                    obj.hC.hStackManager.numSlices = thisRecipe.mosaic.numOpticalPlanes;
                end

                if obj.hC.hStackManager.stackZStepSize ~= sliceThicknessInUM/obj.hC.hStackManager.numSlices; 
                    obj.hC.hStackManager.stackZStepSize = sliceThicknessInUM/obj.hC.hStackManager.numSlices; %Will be uniformly spaced always!
                end


                if strcmp(obj.hC.hDisplay.volumeDisplayStyle,'3D')
                    fprintf('Setting volume display style from 3D to Tiled\n')
                    obj.hC.hDisplay.volumeDisplayStyle='Tiled';
                end

            else
                %Ensure we disable z-scanning if this is not being used
                obj.hC.hStackManager.numSlices = 1;
                obj.hC.hStackManager.stackZStepSize = 0;
            end

        end % applyZstackSettingsFromRecipe

        function success = disarmScanner(obj)
            if obj.hC.active
                obj.logMessage(inputname(1),dbstack,7,'Scanner still in acquisition mode. Can not disarm.')
                success=false;
                return
            end

            obj.hC.extTrigEnable=0;
            obj.hC.hScan2D.mdfData.shutterIDs=obj.defaultShutterIDs; %re-enable shutters
            obj.disableArmedListeners;
            obj.disableTileSaving

            % Return tile display mode to settings more useful to the user
            obj.hC.hDisplay.volumeDisplayStyle='Tiled';
            obj.hC.hDisplay.selectedZs=[];

            success=true;
            fprintf('Disarmed scanner: %s\n', datestr(now))
        end %disarmScanner


        function abortScanning(obj)
            obj.hC.hCycleManager.abort;
        end


        function acquiring = isAcquiring(obj,~,~)
            %Returns true if a focus, loop, or grab is in progress even if the system is not
            %currently acquiring a frame
            if obj.verbose
                fprintf('Hit SIBT.isAcquiring\n')
            end
            acquiring = ~strcmp(obj.hC.acqState,'idle');
            obj.isScannerAcquiring=acquiring;
        end %isAcquiring


        %---------------------------------------------------------------
        % The following methods are not part of scanner. Maybe they should be, we need to decide
        function framePeriod = getFramePeriod(obj) %TODO: this isn't in the abstract class.
            %return the frame period (how long it takes to acquire a frame) in seconds
            framePeriod = obj.hC.hRoiManager.scanFramePeriod;
        end %getFramePeriod


        function scanSettings = returnScanSettings(obj)
            scanSettings.pixelsPerLine = obj.hC.hRoiManager.pixelsPerLine;
            scanSettings.linesPerFrame = obj.hC.hRoiManager.linesPerFrame;
            scanSettings.micronsBetweenOpticalPlanes = obj.hC.hStackManager.stackZStepSize;
            scanSettings.numOpticalSlices = obj.hC.hStackManager.numSlices;
            scanSettings.zoomFactor = obj.hC.hRoiManager.scanZoomFactor;

            scanSettings.scannerMechanicalAnglePP_fast_axis = round(range(obj.hC.hRoiManager.imagingFovDeg(:,1)),3);
            scanSettings.scannerMechanicalAnglePP_slowAxis =  round(range(obj.hC.hRoiManager.imagingFovDeg(:,2)),3);

            scanSettings.FOV_alongColsinMicrons = round(range(obj.hC.hRoiManager.imagingFovUm(:,1)),3);
            scanSettings.FOV_alongRowsinMicrons = round(range(obj.hC.hRoiManager.imagingFovUm(:,2)),3);

            scanSettings.micronsPerPixel_cols = round(scanSettings.FOV_alongColsinMicrons/scanSettings.pixelsPerLine,3);
            scanSettings.micronsPerPixel_rows = round(scanSettings.FOV_alongRowsinMicrons/scanSettings.linesPerFrame,3);

            scanSettings.framePeriodInSeconds = round(1/obj.hC.hRoiManager.scanFrameRate,3);
            scanSettings.volumePeriodInSeconds = round(1/obj.hC.hRoiManager.scanVolumeRate,3);
            scanSettings.pixelTimeInMicroSeconds = round(obj.hC.hScan2D.scanPixelTimeMean * 1E6,4);
            scanSettings.linePeriodInMicroseconds = round(obj.hC.hRoiManager.linePeriod * 1E6,4);
            scanSettings.bidirectionalScan = obj.hC.hScan2D.bidirectional;
            scanSettings.activeChannels = obj.hC.hChannels.channelSave;

            % Beam power
            scanSettings.beamPower= obj.hC.hBeams.powers;
            scanSettings.powerZAdjust = obj.hC.hBeams.pzAdjust; % Bool. If true, we ramped power with depth
            scanSettings.beamPowerLengthConstant = obj.hC.hBeams.lengthConstants; % The length constant used for ramping power
            scanSettings.powerZAdjustType = obj.hC.hBeams.pzCustom; % What sort of adjustment (if empty it's default exponential)

            % Scanner type and version
            scanSettings.scanMode= obj.scannerType;
            scanSettings.scannerID=obj.scannerID;
            scanSettings.version=obj.getVersion;

            %Record the detailed image settings to allow for things like acquisition resumption
            scanSettings.pixEqLinCheckBox = obj.hC.hRoiManager.forceSquarePixelation;
            scanSettings.slowMult = obj.hC.hRoiManager.scanAngleMultiplierSlow;
            scanSettings.fastMult = obj.hC.hRoiManager.scanAngleMultiplierFast;
        end %returnScanSettings


        function setUpTileSaving(obj)
            obj.hC.hScan2D.logFilePath = obj.parent.currentTileSavePath;
            % TODO: oddly, the file counter automatically adjusts so as not to over-write existing data but 
            % I can't see where it does this in my code and ScanImage doesn't do this if I use it interactively.
            obj.hC.hScan2D.logFileCounter = 1; % Start each section with the index at 1. 
            obj.hC.hScan2D.logFileStem = sprintf('%s-%04d',obj.parent.recipe.sample.ID,obj.parent.currentSectionNumber); %TODO: replace with something better
            obj.hC.hChannels.loggingEnable = true;
        end %setUpTileSaving

        function disableTileSaving(obj)
            obj.hC.hChannels.loggingEnable=false;
        end

        function initiateTileScan(obj)
            obj.hC.hScan2D.trigIssueSoftwareAcq;
        end


        function pauseAcquisition(obj)
            obj.acquisitionPaused=true;
        end %pauseAcquisition


        function resumeAcquisition(obj)
            obj.acquisitionPaused=false;
        end %resumeAcquisition


        function maxChans=maxChannelsAvailable(obj)
            maxChans=obj.hC.hChannels.channelsAvailable;
        end %maxChannelsAvailable


        function theseChans = channelsToAcquire(obj,~,~)
            % This is also a listener callback function
            if obj.verbose
                fprintf('Hit SIBT.channelsToAcquire\n')
            end
            theseChans = obj.hC.hChannels.channelSave;
            obj.channelsToSave = theseChans; %store the currently selected channels to save
            obj.flipScanSettingsChanged
        end %channelsToAcquire


        function theseChans = channelsToDisplay(obj)
            theseChans = obj.hC.hChannels.channelDisplay;
        end %channelsToDisplay


        function scannerType = scannerType(obj)
            scannerType = lower(obj.hC.hScan2D.scannerType);
        end %scannerType


        function pix=getPixelsPerLine(obj)
            pix =  obj.hC.hRoiManager.pixelsPerLine;
        end % getPixelsPerLine


        function LUT=getChannelLUT(obj,chanToReturn)
            LUT = obj.hC.hChannels.channelLUT{chanToReturn};
        end %getChannelLUT

        function tearDown(obj)
            % Ensure resonant scanner is off
            if strcmpi(obj.scannerType, 'resonant')
                obj.hC.hScan2D.keepResonantScannerOn=0;
            end

            % Turn off PMTs
            obj.hC.hPmts.powersOn(:) = 0;
        end

        function setImageSize(obj,pixelsPerLine,evnt)
            % Set image size
            %
            % Purpose
            % Change the number of pixels per line and ensure that the number of lines per frame changes 
            % accordingly to maintain the FOV and ensure pixels are square. This is a bit harder than it 
            % needs to be because we allow for non-square images and the way ScanImage deals with this is 
            % clunky. 
            % 
            % Inputs
            % If pixelsPerLine is an integer, this method applies it to ScanImage and ensures that the
            % scan angle multipliers remain the same after the setting was applied. It doesn't alter
            % the objective resolution value.
            %
            % This method can also be run as a callback function, in which case pixelsPerLine is a is
            % the source structure (matlab.ui.container.Menu) and should contain a field called 
            % "UserData" which is a structure that looks like this:
            %
            %       objective: 'nikon16x'
            %   pixelsPerLine: 512
            %    linePerFrame: 1365
            %         micsPix: 0.7850
            %        fastMult: 0.7500
            %        slowMult: 2
            %          objRes: 59.5500
            %
            % This information is then used to apply the scan settings. 

            if isa(pixelsPerLine,'matlab.ui.control.UIControl') % Will be true if we're using a pop-up menu to set the image size
                if ~isprop(pixelsPerLine,'UserData')
                    fprintf('SIBT.setImageSize is used as a CallBack function but finds no field "UserData" in its first input arg. NOT APPLYING IMAGE SIZE TO SCANIMAGE.\n')
                    return
                end
                if isempty(pixelsPerLine.UserData)
                    fprintf('SIBT.setImageSize is used as a CallBack function but finds empty field "UserData" in its first input arg. NOT APPLYING IMAGE SIZE TO SCANIMAGE.\n')
                    return
                end

                settings=pixelsPerLine.UserData(pixelsPerLine.Value);
                if ~isfield(settings,'pixelsPerLine')
                    fprintf('SIBT.setImageSize is used as a CallBack function but finds no field "pixelsPerLine". NOT APPLYING IMAGE SIZE TO SCANIMAGE.\n')
                    return
                end

                pixelsPerLine = settings.pixelsPerLine;
                pixEqLin = settings.pixelsPerLine==settings.linesPerFrame; % Is the setting asking for a square frame?
                fastMult = settings.fastMult;
                slowMult = settings.slowMult;
                objRes = settings.objRes;

            else
                pixEqLin = obj.hC.hRoiManager.pixelsPerLine == obj.hC.hRoiManager.linesPerFrame; % Do we currently have a square image?
                fastMult = [];
                slowMult = [];
                objRes = [];
            end

            %Let's record the image size
            orig = obj.returnScanSettings;

            % Do we have square images?
            pixEqLinCheckBox = obj.hC.hRoiManager.forceSquarePixelation;


            if pixEqLin % is the user asking for square tiles?
                % It's pretty easy to change the image size if we have square images. 
                if ~pixEqLinCheckBox
                    fprintf('Setting Pix=Lin check box in ScanImage CONFIGURATION window to true\n')
                    obj.hC.hRoiManager.forceSquarePixelation=true;
                end
                obj.hC.hRoiManager.pixelsPerLine=pixelsPerLine;

                else

                    if pixEqLinCheckBox
                        fprintf('Setting Pix=Lin check box in ScanImage CONFIGURATION window to false\n')
                        obj.hC.hRoiManager.forceSquarePixelation=false;
                    end

                    % Handle changes in image size if we have rectangular images
                    if isempty(slowMult)
                        slowMult = obj.hC.hRoiManager.scanAngleMultiplierSlow;
                    end
                    if isempty(fastMult)
                        fastMult = obj.hC.hRoiManager.scanAngleMultiplierFast;
                    end

                    obj.hC.hRoiManager.pixelsPerLine=pixelsPerLine;

                    obj.hC.hRoiManager.scanAngleMultiplierFast=fastMult;
                    obj.hC.hRoiManager.scanAngleMultiplierSlow=slowMult;

                    if ~isempty(objRes)
                        obj.hC.objectiveResolution = objRes;
                    end

            end

            % Issue a warning if the FOV of the image has changed after changing the number of pixels. 
            after = obj.returnScanSettings;

            if isempty(objRes)
                % Don't issue the warning if we might change the objective resolution 
                if after.FOV_alongRowsinMicrons ~= orig.FOV_alongRowsinMicrons
                    fprintf('WARNING: FOV along rows changed from %0.3f microns to %0.3f microns\n',...
                        orig.FOV_alongRowsinMicrons, after.FOV_alongRowsinMicrons)
                end

                if after.FOV_alongColsinMicrons ~= orig.FOV_alongColsinMicrons
                    fprintf('WARNING: FOV along cols changed from %0.3f microns to %0.3f microns\n',...
                        orig.FOV_alongColsinMicrons, after.FOV_alongColsinMicrons)
                end
            end
        end %setImageSize

        function applyScanSettings(obj,scanSettings)
            % SIBT.applyScanSettings
            %
            % Applies a saved set of scanSettings in order to return ScanImage to a 
            % a previous state. e.g. used to manually resume an acquisition that was 
            % terminated for some reason.
            %

            if ~isstruct(scanSettings)
                return
            end

            % The following z-stack-related settings don't strictly need to be set, 
            % since they are applied when the scanner is armed.
            obj.hC.hStackManager.stackZStepSize = scanSettings.micronsBetweenOpticalPlanes;
            obj.hC.hStackManager.numSlices = scanSettings.numOpticalSlices;

            % Set the laser power and changing power with depth
            obj.hC.hBeams.powers = scanSettings.beamPower;
            obj.hC.hBeams.pzCustom = scanSettings.powerZAdjustType; % What sort of adjustment (if empty it's default exponential)
            obj.hC.hBeams.lengthConstants = scanSettings.beamPowerLengthConstant;
            obj.hC.hBeams.pzAdjust = scanSettings.powerZAdjust; % Bool. If true, we ramped power with depth

            % Which channels to acquire
            if iscell(scanSettings.activeChannels)
                scanSettings.activeChannels = cell2mat(scanSettings.activeChannels);
            end
            obj.hC.hChannels.channelSave = scanSettings.activeChannels;


            % We set the scan parameters. The order in which these are set matters
            obj.hC.hRoiManager.scanZoomFactor = scanSettings.zoomFactor;
            obj.hC.hScan2D.bidirectional = scanSettings.bidirectionalScan;
            obj.hC.hRoiManager.forceSquarePixelation = scanSettings.pixEqLinCheckBox;

            obj.hC.hRoiManager.pixelsPerLine = scanSettings.pixelsPerLine;
            if ~scanSettings.pixEqLinCheckBox
                obj.hC.hRoiManager.linesPerFrame = scanSettings.linesPerFrame;
            end

            % Set the scan angle multipliers. This is likely only critical if 
            % acquiring rectangular scans.
            obj.hC.hRoiManager.scanAngleMultiplierSlow = scanSettings.slowMult;
            obj.hC.hRoiManager.scanAngleMultiplierFast = scanSettings.fastMult;
        end %applyScanSettings


        function verStr = getVersion(obj)
            verStr=sprintf('ScanImage v%s.%s', obj.hC.VERSION_MAJOR, obj.hC.VERSION_MINOR);
        end % getVersion


        function sr = generateSettingsReport(obj)

            % Bidirectional scanning
            n=1;
            st(n).friendlyName = 'Bidirectional scanning';
            st(n).currentValue = obj.hC.hScan2D.bidirectional;
            st(n).suggestedVal = true;


            % Ramping power with Z
            n=n+1;
            st(n).friendlyName = 'Power Z adjust';
            st(n).currentValue = obj.hC.hBeams.pzAdjust;
            if hC.hStackManager.numSlices>1
                suggested = true;
            elseif hC.hStackManager.numSlices==1 
                % Because then it doesn't matter what this is set to and we don't want to 
                % distract the user with stuff that doesn't matter;
                suggested = obj.hC.hBeams.pzAdjust;
            end
            st(n).suggestedVal = suggested

        end % generateSettingsReport


    end %close methods


    methods (Hidden)
        function lastFrameNumber = getLastFrameNumber(obj)
            % Returns the number of frames acquired by the scanner.
            % In this case it returns the value of "Acqs Done" from the ScanImage main window GUI. 
            lastFrameNumber = obj.hC.hDisplay.lastFrameNumber;
            %TODO: does it return zero if there are no data yet?
            %TODO: turn into a listener that watches lastFrameNumber

        end

        function enableArmedListeners(obj)
            % Loop through all armedListeners and enable each
            for ii=1:length(obj.armedListeners)
                obj.armedListeners{ii}.Enabled=true;
            end
        end % enableArmedListeners

        function disableArmedListeners(obj)
            % Loop through all armedListeners and disable each
            for ii=1:length(obj.armedListeners)
                obj.armedListeners{ii}.Enabled=false;
            end
        end % disableArmedListeners



        %Listener callback methods
        function enforceImportantSettings(obj,~,~)
            %Ensure that a few key settings are maintained at the correct values
            if obj.verbose
                fprintf('Hit SIBT.enforceImportantSettings\n')
            end
            if obj.hC.hRoiManager.forceSquarePixels==false
                obj.hC.hRoiManager.forceSquarePixels=true;
            end
        end %enforceImportantSettings


        function LUTchanged(obj,~,~)
            if obj.verbose
                fprintf('Hit SIBT.LUTchanged\n')
            end
            obj.channelLookUpTablesChanged=obj.channelLookUpTablesChanged*-1; %Just flip it so listeners on other classes notice the change
        end %LUTchanged


        function tileAcqDone(obj,~,~)
            % This callback function is VERY IMPORTANT it constitutes part of the implicit loop
            % that performs the tile scanning. It is an "implicit" loop, since it is called 
            % repeatedly until all tiles have been acquired.

            %Log the X and Y positions in the grid associated with the tile data from the last acquired position
            if ~isempty(obj.parent.positionArray)
                obj.parent.lastTilePos.X = obj.parent.positionArray(obj.parent.currentTilePosition,1);
                obj.parent.lastTilePos.Y = obj.parent.positionArray(obj.parent.currentTilePosition,2);
                obj.parent.lastTileIndex = obj.parent.currentTilePosition;
            else
                fprintf('BT.positionArray is empty. Not logging last tile positions. Likely hBT.runTileScan was not run.\n')
            end

            % Blocking motion
            blocking=true;
            obj.parent.moveXYto(obj.currentTilePattern(obj.parent.currentTilePosition+1,1), ...
                obj.currentTilePattern(obj.parent.currentTilePosition+1,2), blocking); 


            % Import the last frames and downsample them
            if obj.parent.importLastFrames
                msg='';
                for z=1:length(obj.hC.hDisplay.stripeDataBuffer) %Loop through depths
                    % scanimage stores image data in a data structure called 'stripeData'
                    %ptr=obj.hC.hDisplay.stripeDataBufferPointer; % get the pointer to the last acquired stripeData (ptr=1 for z-depth 1, ptr=5 for z-depth, etc)
                    lastStripe = obj.hC.hDisplay.stripeDataBuffer{z};
                    if isempty(lastStripe)
                        msg = sprintf('obj.hC.hDisplay.stripeDataBuffer{%d} is empty. ',z);
                    elseif ~isprop(lastStripe,'roiData')
                        msg = sprintf('obj.hC.hDisplay.stripeDataBuffer{%d} has no field "roiData"',z);
                    elseif ~iscell(lastStripe.roiData)
                        msg = sprintf('Expected obj.hC.hDisplay.stripeDataBuffer{%d}.roiData to be a cell. It is a %s.',z, class(lastStripe.roiData));
                    elseif length(lastStripe.roiData)<1
                        msg = sprintf('Expected obj.hC.hDisplay.stripeDataBuffer{%d}.roiData to be a cell with length >1',z);
                    end

                    if ~isempty(msg)
                        msg = [msg, 'NOT EXTRACTING TILE DATA IN SIBT.tileAcqDone'];
                        obj.logMessage('acqDone',dbstack,6,msg);
                        break
                    end

                    for ii = 1:length(lastStripe.roiData{1}.channels) % Loop through channels
                        obj.parent.downSampledTileBuffer(:, :, lastStripe.frameNumberAcq, lastStripe.roiData{1}.channels(ii)) = ...
                             int16(imresize(rot90(lastStripe.roiData{1}.imageData{ii}{1},-1),...
                                [size(obj.parent.downSampledTileBuffer,1),size(obj.parent.downSampledTileBuffer,2)],'bilinear'));
                    end

                    if obj.verbose
                        fprintf('%d - Placed data from frameNumberAcq=%d (%d) ; frameTimeStamp=%0.4f\n', ...
                            obj.parent.currentTilePosition, ...
                            lastStripe.frameNumberAcq, ...
                            lastStripe.frameNumberAcqMode, ...
                            lastStripe.frameTimestamp)
                    end
                end % z=1:length...
            end % if obj.parent.importLastFrames


            %Increement the counter and make the new position the current one
            obj.parent.currentTilePosition = obj.parent.currentTilePosition+1;

            if obj.parent.currentTilePosition>size(obj.currentTilePattern,1)
                fprintf('hBT.currentTilePosition > number of positions. Breaking in SIBT.tileAcqDone\n')
                return
            end



            % Store stage positions. this is done after all tiles in the z-stack have been acquired
            doFakeLog=false; % Takes about 50 ms each time it talks to the PI stages. 
            % Setting doFakeLog to true will save about 15 minutes over the course of an acquisition but
            % You won't get the real stage positions
            obj.parent.logPositionToPositionArray(doFakeLog) 

            if obj.hC.hChannels.loggingEnable==true
                positionArray = obj.parent.positionArray;
                save(fullfile(obj.parent.currentTileSavePath,'tilePositions.mat'),'positionArray')
            end

            while obj.acquisitionPaused
                pause(0.25)
            end

            obj.initiateTileScan  % Start the next position

            obj.logMessage('acqDone',dbstack,2,'->Completed acqDone<-');
        end %tileAcqDone


        function tileAcqDone_minimal(obj,~,~)
            % Minimal acq done for testing and de-bugging
            obj.parent.currentTilePosition = obj.parent.currentTilePosition+1;
            obj.hC.hScan2D.trigIssueSoftwareAcq;
        end % tileAcqDone_minimal(obj,~,~)


        function tileScanAbortedInScanImage(obj,~,~)
            % This is similar to what happens in the acquisition_view GUI in the "stop_callback"
            if obj.verbose
                fprintf('Hit obj.tileScanAbortedInScanImage\n')
            end
            % Wait for scanner to stop being in acquisition mode
            obj.disableArmedListeners
            obj.abortScanning
            fprintf('Waiting to disarm')
            for ii=1:20
                if ~obj.isAcquiring
                    obj.disarmScanner;
                    return
                end
                fprintf('.')
                pause(0.25)
            end

            %If we get here we failed to disarm
            fprintf('WARNING: failed to disarm scanner.\nYou should try: >> hBT.scanner.disarmScanner\n')
        end %tileScanAbortedInScanImage

    end %hidden methods
end %close classdef