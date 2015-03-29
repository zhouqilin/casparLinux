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

#include "PlaybackHelper.h"
#include <unistd.h>

#define PIXEL_FMT			bmdFormat8BitYUV
#define	BYPASS_TIMEOUT_MS	40
#define NUM_FRAMES	8

// array of colours used to fill in frames
static uint32_t gFrameColours[8] =
{
	0xeb80eb80, 0xa28ea22c, 0x832c839c, 0x703a7048,
	0x54c654b8, 0x41d44164, 0x237223d4, 0x10801080
};

// Get the buffer for an decklink video frame at the given index, and
// fill the buffer with the colour at the same index in the colour array
bool	PlaybackHelper::fillFrame(int index)
{
	bool		result = false;
	long		numWords = m_height * m_width * 2 / 4; // number of words in the frame
	uint32_t	*nextWord = NULL;
	
	if (index >= sizeof(gFrameColours)/sizeof(uint32_t))
		goto bail;

	// Make sure there is an even number of pixels
	if ((m_height * m_width * 2) % 4 != 0)
	{
		printf("Odd number of pixels in buffer !!!\n");
		goto bail;
	}
	
	// get the buffer for our frame
	if (m_videoFrames[index]->GetBytes((void **)&nextWord) != S_OK)
	{
		printf("Could not get pixel buffer\n");
		goto bail;
	}
	
	// fill in the buffer with the right colour
	while(numWords-- > 0)
		*(nextWord++) = gFrameColours[index];
	
	result = true;
	
bail:
	return result;
}

// Create an array of 'NUM_FRAMES' IDeckLinkMutableVideoFrames
// and fill in each frame with its own colour
bool	PlaybackHelper::createFrames()
{
	int i;
	bool result = false;
	
	//allocate and reset frame array
	m_videoFrames = (IDeckLinkMutableVideoFrame **) malloc(NUM_FRAMES * sizeof(IDeckLinkMutableVideoFrame *));
	memset(m_videoFrames, 0x0, NUM_FRAMES * sizeof(IDeckLinkMutableVideoFrame *));
	
	// allocate IDeckLink video frames
	for(i = 0; i<NUM_FRAMES; i++)
	{
		if (m_deckLinkOutput->CreateVideoFrame(m_width, m_height, m_width * 2, bmdFormat8BitYUV, bmdFrameFlagDefault, &m_videoFrames[i]) != S_OK)
		{
			fprintf(stderr, "Could not obtain frame %d\n", (i+1));
			goto bail;
		}		
		
		// fill in frame buffer
		fillFrame(i);				  
	}
	
	result = true;
	
bail:
	if (! result)
		releaseFrames();
	
	return result;
}


// Release each decklink frame and delete the array
void	PlaybackHelper::releaseFrames()
{
	if (m_videoFrames)
	{
		int i;
		// release each frame
		for(i = 0; i<NUM_FRAMES; i++)
		{
			if (m_videoFrames[i])
			{
				m_videoFrames[i]->Release();
				m_videoFrames[i] = NULL;
			}
		}
		
		// delete the array
		free(m_videoFrames);
		m_videoFrames = NULL;
	}
}

// Schedule a single frame or a few frames if pre-rolling
bool	PlaybackHelper::scheduleNextFrame(bool preroll)
{
	bool result = false;
	int iter = preroll ? NUM_FRAMES : 1; // how many frames will we schedule ? NUM_FRAMES if pre-rolling, 1 otherwise
	
	while(iter-- > 0)
	{
		if (m_deckLinkOutput->ScheduleVideoFrame(m_videoFrames[m_nextFrameIndex], (m_totalFrameScheduled * m_frameDuration), m_frameDuration, m_timeScale) == S_OK)
		{
			m_nextFrameIndex = (m_nextFrameIndex == (NUM_FRAMES - 1)) ? 0 : m_nextFrameIndex +1;
			m_totalFrameScheduled++;
			result = true;
		}
		else
		{
			printf("Could not schedule next frame (total frame scheduled: %d)\n", m_totalFrameScheduled);
			break;
		}
	}
	
	return result;
}

bool	PlaybackHelper::setupDeckLinkOutput()
{
	bool							result = false;
    IDeckLinkDisplayModeIterator*	displayModeIterator = NULL;
    IDeckLinkDisplayMode*			deckLinkDisplayMode = NULL;
	
	m_width = -1;
	
	// set callback
	m_deckLinkOutput->SetScheduledFrameCompletionCallback(this);
	
	// get frame scale and duration for the video mode
    if (m_deckLinkOutput->GetDisplayModeIterator(&displayModeIterator) != S_OK)
		goto bail;
	
    while (displayModeIterator->Next(&deckLinkDisplayMode) == S_OK)
    {
		if (deckLinkDisplayMode->GetDisplayMode() == bmdModeNTSC)
		{
			m_width = deckLinkDisplayMode->GetWidth();
			m_height = deckLinkDisplayMode->GetHeight();
			deckLinkDisplayMode->GetFrameRate(&m_frameDuration, &m_timeScale);
			deckLinkDisplayMode->Release();
			
			break;
		}
		
		deckLinkDisplayMode->Release();
    }
	
    displayModeIterator->Release();
	
	if (m_width == -1)
	{
		fprintf(stderr, "Unable to find requested video mode\n");
		goto bail;
	}
	
	// enable video output
	if (m_deckLinkOutput->EnableVideoOutput(bmdModeNTSC, bmdVideoOutputFlagDefault) != S_OK)
	{
		fprintf(stderr, "Could not enable video output\n");
		goto bail;
	}
	
	// create coloured frames
	if (! createFrames())
		goto bail;
	
	result = true;
	
bail:
	if (! result)
	{
		// release coloured frames
		releaseFrames();
	}
	
	return result;
}

void	PlaybackHelper::cleanupDeckLinkOutput()
{
	m_deckLinkOutput->StopScheduledPlayback(0, NULL, 0);
	m_deckLinkOutput->DisableVideoOutput();
	m_deckLinkOutput->SetScheduledFrameCompletionCallback(NULL);
	releaseFrames();
}

bool	PlaybackHelper::startPlayback()
{
	// setup DeckLink Output interface
	if (! setupDeckLinkOutput())
		goto bail;
	
	// preroll a few frames
	if (! scheduleNextFrame(true))
		goto bail;

	// start playback
	if (m_deckLinkOutput->StartScheduledPlayback(0, m_timeScale, 1.0) != S_OK)
	{
		fprintf(stderr, "Could not start playback\n");
		goto bail;
	}
	
	printf("Playback started\n");
	m_playbackStarted = true;
	
	// Start the watchdog pinging thread
	if (pthread_create(&m_watchdogThread, NULL, pingWatchdogFunc, this) != 0)
	{
		fprintf(stderr, "Error starting watchdog pinging thread\n");
		goto bail;
	}

bail:
	if (! m_playbackStarted)
		stopPlayback();
	
	return m_playbackStarted;
}

void	PlaybackHelper::stopPlayback()
{
	m_playbackStarted = false;	// will cause the pinging thread to exit
	
	cleanupDeckLinkOutput();
	printf("Playback stopped\n");
	
	pthread_join(m_watchdogThread, NULL);
}

void*	PlaybackHelper::pingWatchdogFunc(void *arg)
{
	PlaybackHelper* me = (PlaybackHelper* )arg;
	me->pingWatchdog();
	return NULL;
}

void	PlaybackHelper::pingWatchdog()
{
	while(m_playbackStarted)
	{
		// Reset the bypass timeout value
		if (m_configuration->SetInt(bmdDeckLinkConfigBypass, BYPASS_TIMEOUT_MS) != S_OK)
		{
			fprintf(stderr, "Error resetting the bypass timeout value\n");
			break;
		}
		
		// Sleep 10 ms less than the timeout value, so we can reset the value before it expires.
		usleep((BYPASS_TIMEOUT_MS - 10) * 1000); 
	}
	
	// Deactivate bypass before we exit
	m_configuration->SetInt(bmdDeckLinkConfigBypass, -1);
}

#pragma mark IDeckLinkVideoOutputCallback methods
/*
 * IDeckLinkVideoOutputCallback methods
 */
HRESULT	PlaybackHelper::ScheduledFrameCompleted (IDeckLinkVideoFrame* completedFrame, BMDOutputFrameCompletionResult result)
{
	if (m_playbackStarted)
		// Schedule a new frame
		scheduleNextFrame(false);
	
	return S_OK;
}


#pragma mark CTOR DTOR
/*
 * CTOR DTOR
 */
PlaybackHelper::PlaybackHelper(IDeckLink *deckLink)
: m_deckLink(deckLink), m_deckLinkOutput(NULL), m_playbackStarted(false)
, m_videoFrames(NULL), m_nextFrameIndex(0), m_totalFrameScheduled(0)
, m_width(-1), m_height(-1), m_timeScale(0), m_frameDuration(0), m_configuration(NULL)
{
	m_deckLink->AddRef();
}	

PlaybackHelper::~PlaybackHelper()
{
	if (m_configuration)
	{
		m_configuration->Release();
		m_configuration = NULL;
	}
	
	if (m_deckLinkOutput)
	{
		m_deckLinkOutput->Release();
		m_deckLinkOutput = NULL;
	}
	
	if (m_deckLink)
	{
		m_deckLink->Release();
		m_deckLink = NULL;
	}
}

// Call init() before any other method. if init() fails, destroy the object
bool	PlaybackHelper::init()
{
	IDeckLinkAttributes*	attributes = NULL;
	bool					hasBypass;
	bool					result = false;
	
	// Get the IDeckLinkAttributes interface
	if (m_deckLink->QueryInterface(IID_IDeckLinkAttributes, (void **)&attributes) != S_OK)
	{
		printf("Could not get the IdeckLinkAttributes interface\n");
		goto bail;
	}
		
	// Make sure the DeckLink device has a bypass
	if ((attributes->GetFlag(BMDDeckLinkHasBypass, &hasBypass) != S_OK) || ! hasBypass)
	{
		printf("The DeckLink device does not have a bypass\n");
		goto bail;
	}

	// Get the IDeckLinkConfiguration interface
	if (m_deckLink->QueryInterface(IID_IDeckLinkConfiguration, (void **)&m_configuration) != S_OK)
	{
		printf("Could not get the IDeckLinkConfiguration interface\n");
		m_configuration = NULL;
	}
	
	
	// Get the IDeckLinkOutput interface
	if (m_deckLink->QueryInterface(IID_IDeckLinkOutput, (void **)&m_deckLinkOutput) != S_OK)
	{
		printf("Could not get DeckLink Output interface\n");
		m_deckLinkOutput = NULL;
		goto bail;
	}
	
	result = true;
	
bail:
	if (attributes)
		attributes->Release();
	
	return result;
}


