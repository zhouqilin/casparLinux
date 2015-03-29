/* -LICENSE-START-
 ** Copyright (c) 2011 Blackmagic Design
 **
 ** Permission is hereby granted, free of charge, to any person or organization
 ** obtaining a copy of the software and accompanying documentation covered by
 ** this license (the "Software") to use, reproduce, display, distribute,
 ** execute, and transmit the Software, and to prepare derivative works of the
 ** Software, and to permit third-parties to whom the Software is furnished to
 ** do so, all subject to the following:
 ** 
 ** The copyright notices in the Software and this entire statement, including
 ** the above license grant, this restriction and the following disclaimer,
 ** must be included in all copies of the Software, in whole or in part, and
 ** all derivative works of the Software, unless such copies or derivative
 ** works are solely in the form of machine-executable object code generated by
 ** a source language processor.
 ** 
 ** THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 ** IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 ** FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
 ** SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
 ** FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
 ** ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 ** DEALINGS IN THE SOFTWARE.
 ** -LICENSE-END-
 */

#include "DeckLinkController.h"

using namespace std;


DeckLinkDevice::DeckLinkDevice(CapturePreviewAppDelegate* ui, IDeckLink* device) : uiDelegate(ui), deckLink(device), deckLinkInput(NULL), supportFormatDetection(false), refCount(1), currentlyCapturing(false), deviceName(NULL)
{
	// DeckLinkDevice owns IDeckLink instance
	// AddRef has already been called on this IDeckLink instance on our behalf in DeckLinkDeviceArrived to avoid a race
}

DeckLinkDevice::~DeckLinkDevice()
{
	if (deckLinkInput)
	{
		deckLinkInput->Release();
		deckLinkInput = NULL;
	}
	
	if (deckLink)
	{
		deckLink->Release();
		deckLink = NULL;
	}
	
	CFRelease(deviceName);
}

HRESULT         DeckLinkDevice::QueryInterface (REFIID iid, LPVOID *ppv)
{
	CFUUIDBytes		iunknown;
	HRESULT			result = E_NOINTERFACE;
	
	// Initialise the return result
	*ppv = NULL;
	
	// Obtain the IUnknown interface and compare it the provided REFIID
	iunknown = CFUUIDGetUUIDBytes(IUnknownUUID);
	if (memcmp(&iid, &iunknown, sizeof(REFIID)) == 0)
	{
		*ppv = this;
		AddRef();
		result = S_OK;
	}
	else if (memcmp(&iid, &IID_IDeckLinkNotificationCallback, sizeof(REFIID)) == 0)
	{
		*ppv = (IDeckLinkNotificationCallback*)this;
		AddRef();
		result = S_OK;
	}
	
	return result;
}

ULONG       DeckLinkDevice::AddRef (void)
{
	return OSAtomicIncrement32(&refCount);
}

ULONG       DeckLinkDevice::Release (void)
{
	int32_t		newRefValue;
	
	newRefValue = OSAtomicDecrement32(&refCount);
	if (newRefValue == 0)
	{
		delete this;
		return 0;
	}
	
	return newRefValue;
}

bool        DeckLinkDevice::init()
{
	IDeckLinkAttributes*            deckLinkAttributes = NULL;
	IDeckLinkDisplayModeIterator*   displayModeIterator = NULL;
	IDeckLinkDisplayMode*           displayMode = NULL;
	
	// Get input interface
	if (deckLink->QueryInterface(IID_IDeckLinkInput, (void**) &deckLinkInput) != S_OK)
		return false;
	
	// Check if input mode detection format is supported.
	if (deckLink->QueryInterface(IID_IDeckLinkAttributes, (void**) &deckLinkAttributes) == S_OK)
	{
		if (deckLinkAttributes->GetFlag(BMDDeckLinkSupportsInputFormatDetection, &supportFormatDetection) != S_OK)
			supportFormatDetection = false;
		
		deckLinkAttributes->Release();
	}
	
	// Retrieve and cache mode list
	if (deckLinkInput->GetDisplayModeIterator(&displayModeIterator) == S_OK)
	{
		while (displayModeIterator->Next(&displayMode) == S_OK)
			modeList.push_back(displayMode);
		
		displayModeIterator->Release();
	}
	
	// Get device name
	if (deckLink->GetDisplayName(&deviceName) != S_OK)
		deviceName = CFStringCreateCopy(NULL, CFSTR("DeckLink"));
	
	return true;
}

NSMutableArray*		DeckLinkDevice::getDisplayModeNames()
{
	NSMutableArray*		modeNames = [NSMutableArray array];
	int					modeIndex;
	CFStringRef			modeName;
	
	for (modeIndex = 0; modeIndex < modeList.size(); modeIndex++)
	{
		if (modeList[modeIndex]->GetName(&modeName) == S_OK)
		{
			[modeNames addObject:(NSString *)modeName];
			CFRelease(modeName);
		}
		else
		{
			[modeNames addObject:@"Unknown mode"];
		}
	}
	
	return modeNames;
}

bool		DeckLinkDevice::startCapture(int videoModeIndex, IDeckLinkScreenPreviewCallback* screenPreviewCallback)
{
	BMDVideoInputFlags		videoInputFlags;
	
	// Enable input video mode detection if the device supports it
	videoInputFlags = supportFormatDetection ? bmdVideoInputEnableFormatDetection : bmdVideoInputFlagDefault;
	
	// Get the IDeckLinkDisplayMode from the given index
	if ((videoModeIndex < 0) || (videoModeIndex >= modeList.size()))
	{
		[uiDelegate showErrorMessage:@"An invalid display mode was selected." title:@"Error starting the capture"];
		return false;
	}
	
	// Set the screen preview
	deckLinkInput->SetScreenPreviewCallback(screenPreviewCallback);
	
	// Set capture callback
	deckLinkInput->SetCallback(this);
	
	// Set the video input mode
	if (deckLinkInput->EnableVideoInput(modeList[videoModeIndex]->GetDisplayMode(), bmdFormat10BitYUV, videoInputFlags) != S_OK)
	{
		[uiDelegate showErrorMessage:@"This application was unable to select the chosen video mode. Perhaps, the selected device is currently in-use." title:@"Error starting the capture"];
		return false;
	}
	
	// Start the capture
	if (deckLinkInput->StartStreams() != S_OK)
	{
		[uiDelegate showErrorMessage:@"This application was unable to start the capture. Perhaps, the selected device is currently in-use." title:@"Error starting the capture"];
		return false;
	}
	
	currentlyCapturing = true;
	
	return true;
}

void		DeckLinkDevice::stopCapture()
{
	// Stop the capture
	deckLinkInput->StopStreams();
	
	// Delete capture callback
	deckLinkInput->SetCallback(NULL);
    deckLinkInput->DisableVideoInput();
	
	currentlyCapturing = false;
}


HRESULT		DeckLinkDevice::VideoInputFormatChanged (/* in */ BMDVideoInputFormatChangedEvents notificationEvents, /* in */ IDeckLinkDisplayMode *newMode, /* in */ BMDDetectedVideoInputFormatFlags detectedSignalFlags)
{
	UInt32				modeIndex = 0;
	BMDPixelFormat		pixelFormat = bmdFormat10BitYUV;
	
	NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

	if (detectedSignalFlags & bmdDetectedVideoInputRGB444)
		pixelFormat = bmdFormat10BitRGB;

	// Restart capture with the new video mode if told to
	if ([uiDelegate shouldRestartCaptureWithNewVideoMode] == YES)
	{
		// Stop the capture
		deckLinkInput->StopStreams();
		
		// Set the video input mode
		if (deckLinkInput->EnableVideoInput(newMode->GetDisplayMode(), pixelFormat, bmdVideoInputEnableFormatDetection) != S_OK)
		{
			[uiDelegate stopCapture];
			[uiDelegate showErrorMessage:@"This application was unable to select the new video mode." title:@"Error restarting the capture."];
			goto bail;
		}
		
		// Start the capture
		if (deckLinkInput->StartStreams() != S_OK)
		{
			[uiDelegate stopCapture];
			[uiDelegate showErrorMessage:@"This application was unable to start the capture on the selected device." title:@"Error restarting the capture."];
			goto bail;
		}
	}
	
	// Find the index of the new mode in the mode list so we can update the UI
	while (modeIndex < modeList.size()) {
		if (modeList[modeIndex]->GetDisplayMode() == newMode->GetDisplayMode())
		{
			[uiDelegate selectDetectedVideoModeWithIndex: modeIndex];
			break;
		}
		modeIndex++;
	}
	
	
bail:
	[pool release];
	return S_OK;
}

HRESULT 	DeckLinkDevice::VideoInputFrameArrived (/* in */ IDeckLinkVideoInputFrame* videoFrame, /* in */ IDeckLinkAudioInputPacket* audioPacket)
{
	BOOL					hasValidInputSource = (videoFrame->GetFlags() & bmdFrameHasNoInputSource) != 0 ? NO : YES;
	AncillaryDataStruct		ancillaryData;
	
	NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
	
	// Update input source label
	[uiDelegate updateInputSourceState:hasValidInputSource];
	
	// Get the various timecodes and userbits for this frame
	getAncillaryDataFromFrame(videoFrame, bmdTimecodeVITC, &ancillaryData.vitcF1Timecode, &ancillaryData.vitcF1UserBits);
	getAncillaryDataFromFrame(videoFrame, bmdTimecodeVITCField2, &ancillaryData.vitcF2Timecode, &ancillaryData.vitcF2UserBits);
	getAncillaryDataFromFrame(videoFrame, bmdTimecodeRP188VITC1, &ancillaryData.rp188vitc1Timecode, &ancillaryData.rp188vitc1UserBits);
	getAncillaryDataFromFrame(videoFrame, bmdTimecodeRP188LTC, &ancillaryData.rp188ltcTimecode, &ancillaryData.rp188ltcUserBits);
	getAncillaryDataFromFrame(videoFrame, bmdTimecodeRP188VITC2, &ancillaryData.rp188vitc2Timecode, &ancillaryData.rp188vitc2UserBits);
	
	[uiDelegate setAncillaryData:&ancillaryData];
	
	// Update the UI
	dispatch_async(dispatch_get_main_queue(), ^{
		[uiDelegate reloadAncillaryTable];
	});
	
	[pool release];
	return S_OK;
}


void            DeckLinkDevice::getAncillaryDataFromFrame(IDeckLinkVideoInputFrame* videoFrame, BMDTimecodeFormat timecodeFormat, NSString** timecodeString, NSString** userBitsString)
{
	IDeckLinkTimecode*		timecode = NULL;
	CFStringRef				timecodeCFString;
	BMDTimecodeUserBits		userBits = 0;
	
	if ((videoFrame != NULL) && (timecodeString != NULL) && (userBitsString != NULL)
		&& (videoFrame->GetTimecode(timecodeFormat, &timecode) == S_OK))
	{
		if (timecode->GetString(&timecodeCFString) == S_OK)
		{
			*timecodeString = [NSString stringWithString: (NSString *)timecodeCFString];
			CFRelease(timecodeCFString);
		}
		else
		{
			*timecodeString = @"";
		}
		
		timecode->GetTimecodeUserBits(&userBits);
		*userBitsString = [NSString stringWithFormat:@"0x%08X", userBits];
		
		timecode->Release();
	}
	else
	{
		*timecodeString = @"";
		*userBitsString = @"";
	}
}


DeckLinkDeviceDiscovery::DeckLinkDeviceDiscovery(CapturePreviewAppDelegate* delegate)
: uiDelegate(delegate), deckLinkDiscovery(NULL), refCount(1)
{
	deckLinkDiscovery = CreateDeckLinkDiscoveryInstance();
}


DeckLinkDeviceDiscovery::~DeckLinkDeviceDiscovery()
{
	if (deckLinkDiscovery != NULL)
	{
		// Uninstall device arrival notifications and release discovery object
		deckLinkDiscovery->UninstallDeviceNotifications();
		deckLinkDiscovery->Release();
		deckLinkDiscovery = NULL;
	}
}

bool        DeckLinkDeviceDiscovery::Enable()
{
	HRESULT     result = E_FAIL;
	
	// Install device arrival notifications
	if (deckLinkDiscovery != NULL)
		result = deckLinkDiscovery->InstallDeviceNotifications(this);
	
	return result == S_OK;
}

void        DeckLinkDeviceDiscovery::Disable()
{
	// Uninstall device arrival notifications
	if (deckLinkDiscovery != NULL)
		deckLinkDiscovery->UninstallDeviceNotifications();
}

HRESULT     DeckLinkDeviceDiscovery::DeckLinkDeviceArrived (/* in */ IDeckLink* deckLink)
{
	// Update UI (add new device to menu) from main thread
	// AddRef the IDeckLink instance before handing it off to the main thread
	deckLink->AddRef();
	dispatch_async(dispatch_get_main_queue(), ^{
		[uiDelegate addDevice:deckLink];
	});
	
	return S_OK;
}

HRESULT     DeckLinkDeviceDiscovery::DeckLinkDeviceRemoved (/* in */ IDeckLink* deckLink)
{
	dispatch_async(dispatch_get_main_queue(), ^{ [uiDelegate removeDevice:deckLink]; });
	return S_OK;
}

HRESULT         DeckLinkDeviceDiscovery::QueryInterface (REFIID iid, LPVOID *ppv)
{
	CFUUIDBytes		iunknown;
	HRESULT			result = E_NOINTERFACE;
	
	// Initialise the return result
	*ppv = NULL;
	
	// Obtain the IUnknown interface and compare it the provided REFIID
	iunknown = CFUUIDGetUUIDBytes(IUnknownUUID);
	if (memcmp(&iid, &iunknown, sizeof(REFIID)) == 0)
	{
		*ppv = this;
		AddRef();
		result = S_OK;
	}
	else if (memcmp(&iid, &IID_IDeckLinkDeviceNotificationCallback, sizeof(REFIID)) == 0)
	{
		*ppv = (IDeckLinkDeviceNotificationCallback*)this;
		AddRef();
		result = S_OK;
	}
	
	return result;
}

ULONG           DeckLinkDeviceDiscovery::AddRef (void)
{
	return OSAtomicIncrement32(&refCount);
}

ULONG           DeckLinkDeviceDiscovery::Release (void)
{
	int32_t		newRefValue;
	
	newRefValue = OSAtomicDecrement32(&refCount);
	if (newRefValue == 0)
	{
		delete this;
		return 0;
	}
	
	return newRefValue;
}

