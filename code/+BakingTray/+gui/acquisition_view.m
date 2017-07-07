classdef acquisition_view < BakingTray.gui.child_view


    properties
        imageAxes %The preview image sits here
        compassAxes %This houses the compass-like indicator 

        statusPanel %The buttons and panals at the top of the window are kept here
        statusText  %The progress text
        sectionImage %Reference to the Image object (the imageAxis child which displays the image)

        doSectionImageUpdate=true %if false we don't update the image


        %This button initiate bake and then switches to being a stop button
        button_BakeStop
        buttonSettings_BakeStop %Structure that contains the different settings for the two button states

        %The pause buttons and its settings (for enable/disable)
        button_Pause
        buttonSettings_Pause 

        depthSelectPopup
        channelSelectPopup

        button_previewScan
    end

    properties (SetObservable,Transient)
        previewImageData=[]; %This 4D matrix holds the preview image (pixel rows, pixel columns, z depth, channel)
        previewTilePositions %This is where the tiles will go (we take into account the overlap between tiles: see .initialisePreviewImageData)
    end %close hidden transient observable properties

    properties (Hidden,SetAccess=private)
        chanToShow=1
        depthToShow=1
        rotateSectionImage90degrees=true; %Ensure the axis along which the blade cuts is is the image x axis. 
    end %close hidden private properties



    methods
        function obj = acquisition_view(model,parentView)
            obj = obj@BakingTray.gui.child_view;

            if nargin>0
                %TODO: all the obvious checks needed
                obj.model = model;
            else
                fprintf('Can''t build acquisition_view: please supply a BT object\n');
                return
            end

            if nargin>1
                obj.parentView=parentView;
            end

            if ~isempty(obj.parentView)
                obj.parentView.enableDisableThisView('off');
            end

            obj.hFig = BakingTray.gui.newGenericGUIFigureWindow('BakingTray_acquisition');

            % Closing the figure closes the view object
            set(obj.hFig,'CloseRequestFcn', @obj.closeAcqGUI, 'Resize','on')

            % Set the figure window to have a reasonable size
            minFigSize=[800,600];
            LimitFigSize(obj.hFig,'min',minFigSize);
            set(obj.hFig, 'SizeChangedFcn', @obj.updateGUIonResize)
            set(obj.hFig, 'Name', 'BakingTray - Acquisition')

            % Make the status panel
            panelHeight=40;
            obj.statusPanel = BakingTray.gui.newGenericGUIPanel([2, minFigSize(2)-panelHeight, minFigSize(1)-4, panelHeight], obj.hFig);
            if ispc
                textFSize=9;
            else
                textFSize=11;
            end
            obj.statusText = annotation(obj.statusPanel,'textbox', 'Units','Pixels', 'Color', 'w', ...
                                        'Position',[0,1,260,panelHeight-4],'EdgeColor','none',...
                                        'HorizontalAlignment','left', 'VerticalAlignment','middle',...
                                        'FontSize',textFSize);
            %Make the image axes
            obj.imageAxes = axes('parent', obj.hFig, ...
                'Units','pixels', 'Color', 'none',...
                'Position',[3,2,minFigSize(1)-4,minFigSize(2)-panelHeight-4]);

            %Set up the compass plot
            pos=plotboxpos(obj.imageAxes);
            obj.compassAxes = axes('parent', obj.hFig,...
                'Units', 'pixels', 'Color', 'none', ...
                'Position', [pos(1:2),80,80],... %The precise positioning is handled in obj.updateGUIonResize
                'XLim', [-1,1], 'YLim', [-1,1],...
                'XColor','none', 'YColor', 'none');
            hold(obj.compassAxes,'on')
            plot([-0.8,0.64],[0,0],'-r','parent',obj.compassAxes)
            plot([0,0],[-1,1],'-r','parent',obj.compassAxes)
            compassText(1) = text(0.05,0.95,'-x','parent',obj.compassAxes);
            compassText(2) = text(0.05,-0.85,'+x','parent',obj.compassAxes);
            compassText(3) = text(0.65,0.04,'+y','parent',obj.compassAxes);
            compassText(4) = text(-1.08,0.04,'-y','parent',obj.compassAxes);
            set(compassText,'Color','r')
            hold(obj.compassAxes,'off')

            %Set up the bake/stop button
            obj.buttonSettings_BakeStop.bake={'String', 'Bake', ...
                            'Callback', @obj.bake_callback, ...
                            'FontSize', obj.fSize, ...
                            'BackgroundColor', [0.5,1.0,0.5]};

            obj.buttonSettings_BakeStop.stop={'String', 'Stop', ...
                            'Callback', @obj.stop_callback, ...
                            'FontSize', obj.fSize, ...
                            'BackgroundColor', [1,0.5,0.5]};

            obj.buttonSettings_BakeStop.cancelStop={'String', sprintf('<html><p align="center">Cancel<br />Stop</p></html>'), ...
                            'Callback', @obj.stop_callback, ...
                            'FontSize', obj.fSize-1, ...
                            'Callback', @obj.stop_callback, ...
                            'BackgroundColor', [0.95,0.95,0.15]};

            obj.button_BakeStop=uicontrol(...
                'Parent', obj.statusPanel, ...
                'Position', [265, 2, 60, 32], ...
                'Units','Pixels',...
                'ForegroundColor','k', ...
                'FontWeight', 'bold');

            %Ensure the back button reflects what is currently happening
            if ~obj.model.acquisitionInProgress
                set(obj.button_BakeStop, obj.buttonSettings_BakeStop.bake{:})
            else obj.model.acquisitionInProgress
                set(obj.button_BakeStop, obj.buttonSettings_BakeStop.stop{:})
            end


            %Set up the pause button
            obj.buttonSettings_Pause.disabled={...
                            'ForegroundColor',[1,1,1]*0.5,...
                            'String', 'Pause', ...
                            'BackgroundColor', [0.75,0.75,1.0]};

            obj.buttonSettings_Pause.enabled={...
                            'ForegroundColor','k',...
                            'String', 'Pause', ...
                            'BackgroundColor', [1,0.75,0.25]};

            obj.buttonSettings_Pause.resume={...
                            'ForegroundColor','k',...
                            'String', 'Resume', ...
                            'BackgroundColor', [0.5,1.0,0.5]};

            obj.button_Pause=uicontrol(...
                'Parent', obj.statusPanel, ...
                'Position', [330, 2, 60, 32], ...
                'Units','Pixels', ...
                'FontSize', obj.fSize, ...
                'FontWeight', 'bold',...
                'Callback', @obj.pause_callback);
            set(obj.button_Pause, obj.buttonSettings_Pause.disabled{:})


            %Pop-ups for selecting which depth and channel to show
            % Create pop-up menu
            obj.depthSelectPopup = uicontrol('Parent', obj.statusPanel, 'Style', 'popup',...
           'Position', [400, 0, 100, 30], 'String', 'depth', 'Callback', @obj.setDepthToView,...
                      'Interruptible', 'off');


            %Do not proceed if we can not make a tile pattern
            tp=obj.model.recipe.tilePattern;
            if isempty(tp)
                obj.button_BakeStop.Enable='off';
                obj.button_previewScan.Enable='off';
                msg = sprintf(['Your tile pattern likely includes positions that are out of bounds.\n',...
                    'Acuisition will fail. Close this window. Fix the problem. Then try again.\n']);
                if isempty(obj.model.scanner)
                    msg = sprintf('%sLikely cause: no scanner connected\n',msg)
                end
                warndlg(msg,'');
            end


            %Build a blank image
            obj.initialisePreviewImageData
            obj.setUpImageAxes; %Build an empty image of the right size

            % Add the depths
            opticalPlanes_str = {};
            for ii=1:obj.model.recipe.mosaic.numOpticalPlanes
                opticalPlanes_str{end+1} = sprintf('Depth %d',ii);
            end
            if length(opticalPlanes_str)>1 && ~isempty(obj.model.scanner.channelsToDisplay)
                obj.depthSelectPopup.String = opticalPlanes_str;
            else
                obj.depthSelectPopup.String = 'NONE';
                obj.depthSelectPopup.Enable='off';
            end
            obj.setDepthToView; %Ensure that the property is set to a valid depth (it should be anyway)

            obj.channelSelectPopup = uicontrol('Parent', obj.statusPanel, 'Style', 'popup',...
           'Position', [510, 0, 100, 30], 'String', '', 'Callback', @obj.setChannelToView,...
           'Interruptible', 'off');
            % Add the channel names. This is under the control of a listener in case the user makes a 
            % change in ScanImage after the acquisition_view GUI has opened.
            obj.updateChannelsPopup
            obj.setChannelToView %Ensure that the property is set to a valid channel (it may may not be)




            obj.button_previewScan=uicontrol(...
                'Parent', obj.statusPanel, ...
                'Position', [690, 2, 90, 32], ...
                'Units','Pixels',...
                'ForegroundColor','k', ...
                'FontWeight', 'bold', ...
                'String', 'Preview Scan', ...
                'BackgroundColor', [1,0.75,0.25], ...
                'Callback', @obj.startPreviewScan);

            %Add some listeners to monitor properties on the scanner component
            obj.listeners{1}=addlistener(obj.model, 'currentTilePosition', 'PostSet', @obj.placeNewTilesInPreviewData);
            obj.listeners{end+1}=addlistener(obj.model.scanner, 'acquisitionPaused', 'PostSet', @obj.updatePauseButtonState);
            obj.listeners{end+1}=addlistener(obj.model, 'acquisitionInProgress', 'PostSet', @obj.updatePauseButtonState);
            obj.listeners{end+1}=addlistener(obj.model, 'acquisitionInProgress', 'PostSet', @obj.updateBakeButtonState);
            obj.listeners{end+1}=addlistener(obj.model, 'abortAfterSectionComplete', 'PostSet', @obj.updateBakeButtonState);


            obj.listeners{end+1}=addlistener(obj.model.scanner,'channelsToSave', 'PostSet', @obj.updateChannelsPopup);
            obj.listeners{end+1}=addlistener(obj.model.scanner, 'channelLookUpTablesChanged', 'PostSet', @obj.updateImageLUT);
            obj.listeners{end+1}=addlistener(obj.model.scanner, 'isScannerAcquiring', 'PostSet', @obj.updateBakeButtonState);
            obj.listeners{end+1}=addlistener(obj.model, 'isSlicing', 'PostSet', @obj.indicateCutting);

            obj.updateStatusText

        end

        function delete(obj)
            obj.parentView.enableDisableThisView('on');
            obj.parentView.updateStatusText; %Resets the approx time for sample indicator
            delete@BakingTray.gui.child_view(obj);
        end

    end % methods


    methods(Hidden)
        function updateGUIonResize(obj,~,~)
            figPos=obj.hFig.Position;


            %Keep the status panel at the top of the screen and in the centre
            statusPos=obj.statusPanel.Position;
            delta=figPos(3)-statusPos(3); %The number of pixels not covered by the status bar
            obj.statusPanel.Position(1) = round(delta/2);
            obj.statusPanel.Position(2) = figPos(4)-statusPos(4); % Keep at the top

            % Allow the image axes to fill the rest of the space
            imAxesPos=obj.imageAxes.Position;
            obj.imageAxes.Position(3)=figPos(3)-imAxesPos(1)*2+2;
            obj.imageAxes.Position(4)=figPos(4)-statusPos(4)-imAxesPos(2)*2+2;

            pos=plotboxpos(obj.imageAxes);
            obj.compassAxes.Position(1:2) = pos(1:2)+[pos(3)*0.01,pos(4)*0.01];
        end %updateGUIonResize


        function setUpImageAxes(obj)

            blankImage = squeeze(obj.previewImageData(:,:,obj.depthToShow,obj.chanToShow));
            if obj.rotateSectionImage90degrees
                blankImage = rot90(blankImage);
            end

            obj.sectionImage=imagesc(blankImage,'parent',obj.imageAxes);

            set(obj.imageAxes,... 
                'DataAspectRatio',[1,1,1],...
                'XTick',[],...
                'YTick',[],...
                'YDir','normal',...
                'Box','on',...
                'LineWidth',1,...
                'XColor','w',...
                'YColor','w')
            set(obj.hFig,'Colormap', gray(256))

        end %setUpImageAxes


        function initialisePreviewImageData(obj)
            %Calculate where the tiles will go in the preview image

            tp=obj.model.recipe.tilePattern; %Stage positions in mm (x,y)
            if isempty(tp)
                fprintf('ERROR: no tile position data. initialisePreviewImageData can not build empty image\n')
                return
            end
            tp(:,1) = tp(:,1) - tp(1,1);
            tp(:,2) = tp(:,2) - tp(1,2);

            tp=abs(tp);
            tp=round(tp/obj.model.downsampleTileMMperPixel); %TODO: non-square images
            obj.previewTilePositions=tp;

            imCols = range(tp(:,1)) + size(obj.model.downSampledTileBuffer,2);
            imRows = range(tp(:,2)) + size(obj.model.downSampledTileBuffer,1);

            obj.previewImageData = zeros([imRows,imCols, ...
                obj.model.recipe.mosaic.numOpticalPlanes, ...
                obj.model.scanner.maxChannelsAvailable],'int16');

            obj.model.downSampledTileBuffer(:)=0;

            if ~isempty(obj.sectionImage)
                obj.sectionImage.CData(:)=0;
            end

            fprintf('Initialised a preview image of %d columns by %d rows\n', imCols, imRows)
        end %initialisePreviewImageData


        function indicateCutting(obj,~,~)
            % Changes GUI elements accordingly during cutting
            if obj.model.isSlicing
                obj.statusText.String=' ** CUTTING SAMPLE **';
                % TODO: I think these don't work. bake/stop isn't affected and pause doesn't come back. 
                %obj.button_BakeStop.Enable='off';
                %obj.button_Pause.Enable='off';
            else
                obj.updateStatusText
                %obj.updateBakeButtonState
                %obj.updatePauseButtonState
            end
        end %indicateCutting

        function updateStatusText(obj,~,~)
            endTime=obj.model.estimateTimeRemaining;

            obj.statusText.String = sprintf(['Finish time: %s\n', ...
                'Section=%03d/%03d, X=%02d/%02d, Y=%02d/%02d'], ...
                    endTime.expectedFinishTimeString, ...
                    obj.model.currentSectionNumber, ...
                    obj.model.recipe.mosaic.numSections + obj.model.recipe.mosaic.sectionStartNum - 1, ...
                    obj.model.lastTilePos.X, ...
                    obj.model.recipe.NumTiles.X, ...
                    obj.model.lastTilePos.Y, ...
                    obj.model.recipe.NumTiles.Y);
        end %updateStatusText


        function placeNewTilesInPreviewData(obj,~,~)
            % When new tiles are acquired they are placed into the correct location in
            % the obj.previewImageData array. This is run when the tile position increments
            % So it only runs once per X/Y position. 
            obj.updateStatusText
            if obj.model.processLastFrames==false
                return
            end

            %If the current tile position is 1 that means it was reset from it's final value at the end of the last
            %section to 1 by BT.runTileScan. So that indicates the start of a section. If so, we wipe all the 
            %buffer data so we get a blank image
            if obj.model.currentTilePosition==1
                obj.initialisePreviewImageData;
            end

            if obj.model.lastTilePos.X>0 && obj.model.lastTilePos.Y>0
                % Caution changing these lines: tiles may be rectangular
                %Where to place the tile
                y = (1:size(obj.model.downSampledTileBuffer,1)) + obj.previewTilePositions(obj.model.lastTileIndex,2);
                x = (1:size(obj.model.downSampledTileBuffer,2)) + obj.previewTilePositions(obj.model.lastTileIndex,1);

                % NOTE: do not write to obj.model.downSampled tiles. Only the scanner should write to this.

                %Place the tiles into the full image grid so it can be plotted (there is a listener on this property to update the plot)
                obj.previewImageData(y,x,:,:) = obj.model.downSampledTileBuffer;
                obj.updateSectionImage

                obj.model.downSampledTileBuffer(:) = 0; %wipe the buffer 
            end % obj.model.lastTilePos.X>0 && obj.model.lastTilePos.Y>0

        end %placeNewTilesInPreviewData

        function updateSectionImage(obj,~,~)
            % This callback function updates when the listener on obj.previewImageData fires or if the user 
            % updates the popup boxes for depth or channel

            if ~obj.doSectionImageUpdate
                return
            end

            %Raise a console warning if it looks like the image has grown in size
            %TODO: this check can be removed eventually, once we're sure this does not happen ever.
            if numel(obj.sectionImage.CData) < numel(squeeze(obj.previewImageData(:,:,obj.depthToShow, obj.chanToShow)))
                fprintf('The preview image data in the acquisition GUI grew in size\n')
            end

            if obj.rotateSectionImage90degrees
                obj.sectionImage.CData = rot90(squeeze(obj.previewImageData(:,:,obj.depthToShow, obj.chanToShow)));
            else
                obj.sectionImage.CData = squeeze(obj.previewImageData(:,:,obj.depthToShow, obj.chanToShow));
            end

        end %updateSectionImage


        % -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  - 
        function bake_callback(obj,~,~)
            %Check whether it's safe to begin
            [acqPossible, msg]=obj.model.checkIfAcquisitionIsPossible;
            if ~acqPossible
                if ~isempty(msg)
                    warndlg(msg,'');
                end
               return
            end

            obj.initialisePreviewImageData;
            obj.chooseChanToDisplay %By default display the channel shown in ScanImage


            set(obj.button_Pause, obj.buttonSettings_Pause.enabled{:})
            obj.button_BakeStop.Enable='off'; %This gets re-enabled when the scanner starts imaging

            obj.updateImageLUT;

            obj.model.bake;

        end %bake_callback


        function stop_callback(obj,~,~)
            % If the system has not been told to stop after the next section, pressing the 
            % button again will stop this from happening. Otherwise we proceed with the 
            % question dialog. Also see SIBT.tileScanAbortedInScanImage
            if obj.model.abortAfterSectionComplete
                obj.model.abortAfterSectionComplete=false;
                return
            end

            stopNow='Yes: stop NOW';

            stopAfterSection='Yes: stop after this section';
            noWay= 'No way';
            choice = questdlg('Are you sure you want to stop acquisition?', '', stopNow, stopAfterSection, noWay, noWay);

            switch choice
                case stopNow

                    %If the acquisition is paused we un-pause then stop. No need to check if it's paused.
                    obj.model.scanner.resumeAcquisition;

                    %TODO: these three lines also appear in BT.bake
                    obj.model.leaveLaserOn=true; %TODO: we could have a GUI come up that allows the user to choose if they want this happen.
                    obj.model.scanner.abortScanning;
                    obj.model.scanner.disarmScanner;
                    obj.model.detachLogObject;
                    set(obj.button_Pause, obj.buttonSettings_Pause.disabled{:})

                case stopAfterSection
                    %If the acquisition is paused we resume it then it will go on to stop.
                    obj.model.scanner.resumeAcquisition;
                    obj.model.abortAfterSectionComplete=true;

                otherwise
                    %Nothing happens
            end 
        end %stop_callback


        function pause_callback(obj,~,~)
            % Pauses or resumes the acquisition according to the state of the observable property in scanner.acquisitionPaused
            % This will not pause cutting. It will only pause the system when it's acquiring data. If you press this during
            % cutting the acquisition of the next section will not begin until pause is disabled. 
            if ~obj.model.acquisitionInProgress
                obj.updatePauseButtonState;
                return
            end

            if obj.model.scanner.acquisitionPaused
                %If acquisition is paused then we resume it
                obj.model.scanner.resumeAcquisition;
            elseif ~obj.model.scanner.acquisitionPaused
                %If acquisition is running then we pause it
                obj.model.scanner.pauseAcquisition;
            end

        end %pause_callback

        function startPreviewScan(obj,~,~)
            %Starts a rapd, one depth, preview scan. 

            %TODO: The warning dialog in case of failure to scan is created in BT.takeRapidPreview
            %       Ideally it should be here, to matach what happens elsewhere, but this is not 
            %       possible right now because we have to transiently change the sample ID to have
            %       the acquisition proceed if data already exist in the sample directory. Once this
            %       is fixed somehow the dialog creation will come here. 

            %Disable depth selector since we have just one depth
            depthEnableState=obj.depthSelectPopup.Enable;
            obj.depthSelectPopup.Enable='off';
            obj.button_BakeStop.Enable='off'; %This gets re-enabled when the scanner starts imaging

            obj.chooseChanToDisplay %By default display the channel shown in ScanImage

            if size(obj.previewImageData,3)>1
                %A bit nasty but temporarily wipe the higher depths (they'll be re-made later)
                obj.previewImageData(:,:,2:end,:)=[];
            end
            obj.model.takeRapidPreview

            %Ensure the bakeStop button is enabled if BT.takeRapidPreview failed to run
            obj.button_BakeStop.Enable='on'; 
            obj.depthSelectPopup.Enable=depthEnableState; %return to original state
        end %startPreviewScan

        function updatePauseButtonState(obj,~,~)
            if ~obj.model.acquisitionInProgress
                set(obj.button_Pause, obj.buttonSettings_Pause.disabled{:})
            elseif obj.model.acquisitionInProgress && ~obj.model.scanner.acquisitionPaused
                set(obj.button_Pause, obj.buttonSettings_Pause.enabled{:})

            elseif obj.model.acquisitionInProgress && obj.model.scanner.acquisitionPaused
                set(obj.button_Pause, obj.buttonSettings_Pause.resume{:})
            end
        end %updatePauseButtonState


        function updateBakeButtonState(obj,~,~)

            if obj.model.acquisitionInProgress && ~obj.model.scanner.isAcquiring 
                obj.button_BakeStop.Enable='off';
            else
                obj.button_BakeStop.Enable='on';
            end

            if ~obj.model.acquisitionInProgress 
                %If there is no acquisition we put buttons into a state where one can be started
                set(obj.button_BakeStop, obj.buttonSettings_BakeStop.bake{:})
                obj.button_previewScan.Enable='on';

            elseif obj.model.acquisitionInProgress && ~obj.model.abortAfterSectionComplete
                %If there is an acquisition in progress and we're not waiting to abort after this section
                %then it's allowed to have a stop option.
                set(obj.button_BakeStop, obj.buttonSettings_BakeStop.stop{:})
                obj.button_previewScan.Enable='off';

            elseif obj.model.acquisitionInProgress && obj.model.abortAfterSectionComplete
                %If there is an acquisition in progress and we *are* waiting to abort after this section
                %then we are give the option to cancel stop.
                set(obj.button_BakeStop, obj.buttonSettings_BakeStop.cancelStop{:})
                obj.button_previewScan.Enable='off';
            end

        end %updateBakeButtonState


        function closeAcqGUI(obj,~,~)
            %Confirm whether to really quit the GUI. Don't allow it during acquisition 
            if obj.model.acquisitionInProgress
                warndlg('An acquisition is in progress. Stop acquisition before closing GUI.','')
                return
            end

            choice = questdlg(sprintf('Are you sure you want to close the Acquire GUI?\nBakingTray will stay open.'), '', 'Yes', 'No', 'No');

            switch choice
                case 'No'
                    %pass
                case 'Yes'
                    obj.delete
            end
        end


        function updateImageLUT(obj,~,~)
            %TODO: update with SIBT properties
            if obj.model.isScannerConnected
                thisLut=obj.model.scanner.getChannelLUT(obj.chanToShow);
                obj.imageAxes.CLim=thisLut;
            end
        end %updateImageLUT

        function updateChannelsPopup(obj,~,~)
            if obj.model.isScannerConnected
                % Active channels are those being displayed, since with resonant scanning
                % if it's not displayed we have no access to the image data. This isn't
                % the case with galvo/galvo, unfortunately, but we'll just proceed like this
                % and hope galvo/galvo works OK.
                activeChannels = obj.model.scanner.channelsToDisplay;
                activeChannels_str = {};
                for ii=1:length(activeChannels)
                    activeChannels_str{end+1} = sprintf('Channel %d',activeChannels(ii));
                end

                if ~isempty(activeChannels)
                    obj.channelSelectPopup.String = activeChannels_str;
                    obj.channelSelectPopup.Enable='on';
                else
                    obj.channelSelectPopup.String='NONE';
                    obj.channelSelectPopup.Enable='off';
                end
            end
        end %updateChannelsPopup

        function setDepthToView(obj,~,~)
            % This callback runs when the user ineracts with the depth popup.
            % The callback sets which depth will be displayed
            if isempty(obj.model.scanner.channelsToDisplay)
                %Don't do anything if no channels are being viewed
                return
            end
            if strcmp(obj.depthSelectPopup.Enable,'off')
                return
            end
            thisSelection = obj.depthSelectPopup.String{obj.depthSelectPopup.Value};
            thisDepthIndex = str2double(regexprep(thisSelection,'\w+ ',''));
            obj.depthToShow = thisDepthIndex;
            obj.updateSectionImage;
        end %setDepthToView

        function setChannelToView(obj,~,~)
            % This callback runs when the user ineracts with the channel popup.
            % The callback sets which channel will be displayed
            if isempty(obj.model.scanner.channelsToDisplay)
                %Don't do anything if no channels are being viewed
                return
            end
            thisSelection = obj.channelSelectPopup.String{obj.channelSelectPopup.Value};
            thisChannelIndex = str2double(regexprep(thisSelection,'\w+ ',''));
            if isempty(thisChannelIndex)
                return
            end
            obj.chanToShow=thisChannelIndex;
            obj.updateSectionImage;
            obj.updateImageLUT;
        end %setDepthToView

        function chooseChanToDisplay(obj)
            % Choose a channel to display as a default: the first saved and displayed channel
            channelsBeingAcquired = obj.model.scanner.channelsToAcquire;
            channelsScannerDisplays = obj.model.scanner.channelsToDisplay;

            if isempty(channelsScannerDisplays)
                % Then we can't display anything
                return
            end

            f=find(channelsScannerDisplays == channelsBeingAcquired);
            obj.channelSelectPopup.Value=f(1);
            obj.setChannelToView
        end %chooseChanToDisplay

    end %close hidden methods


end
