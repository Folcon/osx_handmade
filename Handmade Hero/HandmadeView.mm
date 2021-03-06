/* ========================================================================
   $File: $
   $Date: $
   $Revision: $
   $Creator: Jeff Buck $
   $Notice: (C) Copyright 2014. All Rights Reserved. $
   ======================================================================== */

/*
	TODO(jeff): THIS IS NOT A FINAL PLATFORM LAYER!!!

	This will be updated to keep parity with Casey's win32 platform layer.
	See his win32_handmade.cpp file for TODO details.
*/


#include <Cocoa/Cocoa.h>

#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>
#import <OpenGL/glext.h>
#import <OpenGL/glu.h>
#import <CoreVideo/CVDisplayLink.h>

#import <AudioUnit/AudioUnit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <IOKit/hid/IOHIDLib.h>

#include <sys/stat.h>

#include <mach/mach_time.h>

#include <pthread.h>
#include <unistd.h>


#ifdef HANDMADE_MIN_OSX
#include "handmade_platform.h"
#else
#include "../handmade/handmade_platform.h"
#endif

#include "osx_handmade.h"
#include "HandmadeView.h"


//#pragma clang diagnostic push
//#pragma clang diagnostic ignored "-Wnull-dereference"
//#pragma clang diagnostic ignored "-Wc++11-compat-deprecated-writable-strings"
//#pragma clang diagnostic pop

global_variable bool32 GlobalPause;

#define STRINGIFY(S) #S

#if HANDMADE_INTERNAL
DEBUG_PLATFORM_EXECUTE_SYSTEM_COMMAND(DEBUGExecuteSystemCommand)
{
    debug_executing_process Result = {};

	char* Args[] = {"/bin/sh",
					STRINGIFY(DYNAMIC_COMPILE_COMMAND),
	                0};

	char* WorkingDirectory = STRINGIFY(DYNAMIC_COMPILE_PATH);

	int PID = fork();

	switch(PID)
	{
		case -1:
			printf("Error forking process: %d\n", PID);
			break;

		case 0:
		{
			// child
			chdir(WorkingDirectory);
			int ExecCode = execvp(Args[0], Args);
			if (ExecCode == -1)
			{
				printf("Error in execve: %d\n", errno);
			}
			break;
		}

		default:
			// parent
			printf("Launched child process %d\n", PID);
			break;
	}


	Result.OSHandle = PID;

    return(Result);
}


DEBUG_PLATFORM_GET_PROCESS_STATE(DEBUGGetProcessState)
{
	debug_process_state Result = {};

	int PID = (int)Process.OSHandle;
	int ExitCode = 0;

	if (PID > 0)
	{
		Result.StartedSuccessfully = true;
	}

	if (waitpid(PID, &ExitCode, WNOHANG) == PID)
	{
		Result.ReturnCode = WEXITSTATUS(ExitCode);
		printf("Child process %d exited with code %d...\n", PID, ExitCode);
	}
	else
	{
		Result.IsRunning = true;
	}

    return(Result);
}
#endif

#define MAX_HID_BUTTONS 32

// TODO(jeff): Temporary NSObject for testing.
// Replace with simple struct in a set of hash tables.
@interface HandmadeHIDElement : NSObject
{
@public
	long	type;
	long	page;
	long	usage;
	long	min;
	long	max;
};

- (id)initWithType:(long)type usagePage:(long)p usage:(long)u min:(long)n max:(long)x;

@end


@interface HandmadeView ()
{
@public
	// display
	CVDisplayLinkRef			_displayLink;

	// graphics
	NSDictionary*				_fullScreenOptions;
	GLuint						_textureId;

	// input
	IOHIDManagerRef				_hidManager;
	int							_hidX;
	int							_hidY;
	uint8						_hidButtons[MAX_HID_BUTTONS];

	char _sourceGameCodeDLFullPath[OSX_STATE_FILENAME_COUNT];

	game_memory					_gameMemory;
	game_offscreen_buffer		_renderBuffer;

	game_input					_input[2];
	game_input*					_newInput;
	game_input*					_oldInput;
	game_input					_currentInput;

	osx_state					_osxState;
	osx_game_code				_game;
	osx_sound_output			_soundOutput;

	platform_work_queue			_highPriorityQueue;
	platform_work_queue			_lowPriorityQueue;

	int32						_targetFramesPerSecond;
	real32						_targetSecondsPerFrame;

	real64						_machTimebaseConversionFactor;
	BOOL						_setupComplete;

	// TODO(jeff): Replace with set of simple hash tables of structs
	NSMutableDictionary*		_elementDictionary;

	BOOL						_glFallbackMode;

	BOOL						_renderAtHalfSpeed;

	u64							_lastCounter;
}
@end


#if 1 // Handmade Hero Sound Buffer
OSStatus OSXAudioUnitCallback(void * inRefCon,
                              AudioUnitRenderActionFlags * ioActionFlags,
                              const AudioTimeStamp * inTimeStamp,
                              UInt32 inBusNumber,
                              UInt32 inNumberFrames,
                              AudioBufferList * ioData)
{
	// NOTE(jeff): Don't do anything too time consuming in this function.
	//             It is a high-priority "real-time" thread.
	//             Even too many printf calls can throw off the timing.
	#pragma unused(ioActionFlags)
	#pragma unused(inTimeStamp)
	#pragma unused(inBusNumber)

	//double currentPhase = *((double*)inRefCon);

	osx_sound_output* SoundOutput = ((osx_sound_output*)inRefCon);


	if (SoundOutput->ReadCursor == SoundOutput->WriteCursor)
	{
		SoundOutput->SoundBuffer.SampleCount = 0;
		//printf("AudioCallback: No Samples Yet!\n");
	}

	//printf("AudioCallback: SampleCount = %d\n", SoundOutput->SoundBuffer.SampleCount);

	int SampleCount = inNumberFrames;
	if (SoundOutput->SoundBuffer.SampleCount < inNumberFrames)
	{
		SampleCount = SoundOutput->SoundBuffer.SampleCount;
	}

	int16* outputBufferL = (int16 *)ioData->mBuffers[0].mData;
	int16* outputBufferR = (int16 *)ioData->mBuffers[1].mData;

	for (UInt32 i = 0; i < SampleCount; ++i)
	{
		outputBufferL[i] = *SoundOutput->ReadCursor++;
		outputBufferR[i] = *SoundOutput->ReadCursor++;

		if ((char*)SoundOutput->ReadCursor >= (char*)((char*)SoundOutput->CoreAudioBuffer + SoundOutput->SoundBufferSize))
		{
			//printf("Callback: Read cursor wrapped!\n");
			SoundOutput->ReadCursor = SoundOutput->CoreAudioBuffer;
		}
	}

	for (UInt32 i = SampleCount; i < inNumberFrames; ++i)
	{
		outputBufferL[i] = 0.0;
		outputBufferR[i] = 0.0;
	}

	return noErr;
}

#else // Test Sine Wave

OSStatus SineWaveRenderCallback(void * inRefCon,
                                AudioUnitRenderActionFlags * ioActionFlags,
                                const AudioTimeStamp * inTimeStamp,
                                UInt32 inBusNumber,
                                UInt32 inNumberFrames,
                                AudioBufferList * ioData)
{
	#pragma unused(ioActionFlags)
	#pragma unused(inTimeStamp)
	#pragma unused(inBusNumber)

	//double currentPhase = *((double*)inRefCon);

	osx_sound_output* SoundOutput = ((osx_sound_output*)inRefCon);

	int16* outputBuffer = (int16 *)ioData->mBuffers[0].mData;
	const double phaseStep = (SoundOutput->Frequency
							   / SoundOutput->SoundBuffer.SamplesPerSecond)
		                     * (2.0 * M_PI);

	for (UInt32 i = 0; i < inNumberFrames; i++)
	{
		outputBuffer[i] = 5000 * sin(SoundOutput->RenderPhase);
		SoundOutput->RenderPhase += phaseStep;
	}

	// Copy to the stereo (or the additional X.1 channels)
	for(UInt32 i = 1; i < ioData->mNumberBuffers; i++)
	{
		memcpy(ioData->mBuffers[i].mData, outputBuffer, ioData->mBuffers[i].mDataByteSize);
	}

	return noErr;
}

OSStatus SilentCallback(void* inRefCon,
                        AudioUnitRenderActionFlags* ioActionFlags,
                        const AudioTimeStamp* inTimeStamp,
                        UInt32 inBusNumber,
                        UInt32 inNumberFrames,
                        AudioBufferList* ioData)
{
	#pragma unused(inRefCon)
	#pragma unused(ioActionFlags)
	#pragma unused(inTimeStamp)
	#pragma unused(inBusNumber)

	//double currentPhase = *((double*)inRefCon);
	//osx_sound_output* SoundOutput = ((osx_sound_output*)inRefCon);

	Float32* outputBuffer = (Float32 *)ioData->mBuffers[0].mData;

	for (UInt32 i = 0; i < inNumberFrames; i++)
	{
		outputBuffer[i] = 0.0;
	}

	// Copy to the stereo (or the additional X.1 channels)
	for(UInt32 i = 1; i < ioData->mNumberBuffers; i++)
	{
		memcpy(ioData->mBuffers[i].mData, outputBuffer,
		       ioData->mBuffers[i].mDataByteSize);
	}

	return noErr;
}
#endif


#if 0 // Use AudioQueues
void OSXAudioQueueCallback(void* data, AudioQueueRef queue, AudioQueueBufferRef buffer)
{
	osx_sound_output* SoundOutput = ((osx_sound_output*)data);

	int16* outputBuffer = (int16 *)ioData->mBuffers[0].mData;
	const double phaseStep = (SoundOutput->Frequency / SoundOutput->SamplesPerSecond) * (2.0 * M_PI);

	for (UInt32 i = 0; i < inNumberFrames; i++)
	{
		outputBuffer[i] = 5000 * sin(SoundOutput->RenderPhase);
		SoundOutput->RenderPhase += phaseStep;
	}

	// Copy to the stereo (or the additional X.1 channels)
	for(UInt32 i = 1; i < ioData->mNumberBuffers; i++)
	{
		memcpy(ioData->mBuffers[i].mData, outputBuffer, ioData->mBuffers[i].mDataByteSize);
	}
}


void OSXInitCoreAudio(osx_sound_output* SoundOutput)
{
	SoundOutput->AudioDescriptor.mSampleRate       = SoundOutput->SamplesPerSecond;
	SoundOutput->AudioDescriptor.mFormatID         = kAudioFormatLinearPCM;
	SoundOutput->AudioDescriptor.mFormatFlags      = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked;
	SoundOutput->AudioDescriptor.mFramesPerPacket  = 1;
	SoundOutput->AudioDescriptor.mChannelsPerFrame = 2;
	SoundOutput->AudioDescriptor.mBitsPerChannel   = sizeof(int16) * 8;
	SoundOutput->AudioDescriptor.mBytesPerFrame    = sizeof(int16); // don't multiply by channel count with non-interleaved!
	SoundOutput->AudioDescriptor.mBytesPerPacket   = SoundOutput->AudioDescriptor.mFramesPerPacket * SoundOutput->AudioDescriptor.mBytesPerFrame;

	uint32 err = AudioQueueNewOutput(&SoundOutput->AudioDescriptor, OSXAudioQueueCallback, SoundOutput, NULL, 0, 0, &SoundOutput->AudioQueue);
	if (err)
	{
		printf("Error in AudioQueueNewOutput\n");
	}

}

#else // Use raw AudioUnits

void OSXInitCoreAudio(osx_sound_output* SoundOutput)
{
	AudioComponentDescription acd;
	acd.componentType         = kAudioUnitType_Output;
	acd.componentSubType      = kAudioUnitSubType_DefaultOutput;
	acd.componentManufacturer = kAudioUnitManufacturer_Apple;

	AudioComponent outputComponent = AudioComponentFindNext(NULL, &acd);

	AudioComponentInstanceNew(outputComponent, &SoundOutput->AudioUnit);
	AudioUnitInitialize(SoundOutput->AudioUnit);

#if 1 // uint16
	//AudioStreamBasicDescription asbd;
	SoundOutput->AudioDescriptor.mSampleRate       = SoundOutput->SoundBuffer.SamplesPerSecond;
	SoundOutput->AudioDescriptor.mFormatID         = kAudioFormatLinearPCM;
	SoundOutput->AudioDescriptor.mFormatFlags      = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked;
	SoundOutput->AudioDescriptor.mFramesPerPacket  = 1;
	SoundOutput->AudioDescriptor.mChannelsPerFrame = 2; // Stereo
	SoundOutput->AudioDescriptor.mBitsPerChannel   = sizeof(int16) * 8;
	SoundOutput->AudioDescriptor.mBytesPerFrame    = sizeof(int16); // don't multiply by channel count with non-interleaved!
	SoundOutput->AudioDescriptor.mBytesPerPacket   = SoundOutput->AudioDescriptor.mFramesPerPacket * SoundOutput->AudioDescriptor.mBytesPerFrame;
#else // floating point - this is the "native" format on the Mac
	AudioStreamBasicDescription asbd;
	SoundOutput->AudioDescriptor.mSampleRate       = SoundOutput->SamplesPerSecond;
	SoundOutput->AudioDescriptor.mFormatID         = kAudioFormatLinearPCM;
	SoundOutput->AudioDescriptor.mFormatFlags      = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
	SoundOutput->AudioDescriptor.mFramesPerPacket  = 1;
	SoundOutput->AudioDescriptor.mChannelsPerFrame = 2;
	SoundOutput->AudioDescriptor.mBitsPerChannel   = sizeof(Float32) * 8; // 1 * sizeof(Float32) * 8;
	SoundOutput->AudioDescriptor.mBytesPerFrame    = sizeof(Float32);
	SoundOutput->AudioDescriptor.mBytesPerPacket   = SoundOutput->AudioDescriptor.mFramesPerPacket * SoundOutput->AudioDescriptor.mBytesPerFrame;
#endif


	// TODO(jeff): Add some error checking...
	AudioUnitSetProperty(SoundOutput->AudioUnit,
                         kAudioUnitProperty_StreamFormat,
                         kAudioUnitScope_Input,
                         0,
                         &SoundOutput->AudioDescriptor,
                         sizeof(SoundOutput->AudioDescriptor));

	AURenderCallbackStruct cb;
	cb.inputProc = OSXAudioUnitCallback;
	cb.inputProcRefCon = SoundOutput;

	AudioUnitSetProperty(SoundOutput->AudioUnit,
                         kAudioUnitProperty_SetRenderCallback,
                         kAudioUnitScope_Global,
                         0,
                         &cb,
                         sizeof(cb));

	AudioOutputUnitStart(SoundOutput->AudioUnit);
}


void OSXStopCoreAudio(osx_sound_output* SoundOutput)
{
	NSLog(@"Stopping Core Audio");
	AudioOutputUnitStop(SoundOutput->AudioUnit);
	AudioUnitUninitialize(SoundOutput->AudioUnit);
	AudioComponentInstanceDispose(SoundOutput->AudioUnit);
}

#endif



void OSXHIDAdded(void* context, IOReturn result, void* sender, IOHIDDeviceRef device)
{
	#pragma unused(context)
	#pragma unused(result)
	#pragma unused(sender)
	#pragma unused(device)

	HandmadeView* view = (__bridge HandmadeView*)context;

	//IOHIDManagerRef mr = (IOHIDManagerRef)sender;

	CFStringRef manufacturerCFSR = (CFStringRef)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDManufacturerKey));
	CFStringRef productCFSR = (CFStringRef)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));

	NSLog(@"Gamepad was detected: %@ %@", (__bridge NSString*)manufacturerCFSR, (__bridge NSString*)productCFSR);

	//NSArray *elements = (__bridge_transfer NSArray *)IOHIDDeviceCopyMatchingElements(device, NULL, kIOHIDOptionsTypeNone);
	NSArray *elements = (__bridge NSArray *)IOHIDDeviceCopyMatchingElements(device, NULL, kIOHIDOptionsTypeNone);

	for (id element in elements)
	{
		IOHIDElementRef tIOHIDElementRef = (__bridge IOHIDElementRef)element;

		IOHIDElementType tIOHIDElementType = IOHIDElementGetType(tIOHIDElementRef);

#if 0
		switch(tIOHIDElementType)
		{
			case kIOHIDElementTypeInput_Misc:
			{
				printf("[misc] ");
				break;
			}

			case kIOHIDElementTypeInput_Button:
			{
				printf("[button] ");
				break;
			}

			case kIOHIDElementTypeInput_Axis:
			{
				printf("[axis] ");
				break;
			}

			case kIOHIDElementTypeInput_ScanCodes:
			{
				printf("[scancode] ");
				break;
			}
			default:
				continue;
		}
#endif


		uint32_t reportSize = IOHIDElementGetReportSize(tIOHIDElementRef);
		uint32_t reportCount = IOHIDElementGetReportCount(tIOHIDElementRef);
		if ((reportSize * reportCount) > 64)
		{
			continue;
		}

		uint32_t usagePage = IOHIDElementGetUsagePage(tIOHIDElementRef);
		uint32_t usage = IOHIDElementGetUsage(tIOHIDElementRef);
		if (!usagePage || !usage)
		{
			continue;
		}
		if (-1 == usage)
		{
			continue;
		}

		CFIndex logicalMin = IOHIDElementGetLogicalMin(tIOHIDElementRef);
		CFIndex logicalMax = IOHIDElementGetLogicalMax(tIOHIDElementRef);

		//printf("page/usage = %d:%d  min/max = (%ld, %ld)\n", usagePage, usage, logicalMin, logicalMax);

		// TODO(jeff): Change NSDictionary to a simple hash table.
		// TODO(jeff): Add a hash table for each controller. Use cookies for ID.
		// TODO(jeff): Change HandmadeHIDElement to a simple struct.
		HandmadeHIDElement* e = [[HandmadeHIDElement alloc] initWithType:tIOHIDElementType
															   usagePage:usagePage
																   usage:usage
																	 min:logicalMin
																	 max:logicalMax];
		long key = (usagePage << 16) | usage;

		[view->_elementDictionary setObject:e forKey:[NSNumber numberWithLong:key]];
	}
}

static void
OSXProcessKeyboardMessage(game_button_state *NewState, bool32 IsDown)
{
	if(NewState->EndedDown != IsDown)
	{
		NewState->EndedDown = IsDown;
		++NewState->HalfTransitionCount;
	}
}

void OSXHIDRemoved(void* context, IOReturn result, void* sender, IOHIDDeviceRef device)
{
	#pragma unused(context)
	#pragma unused(result)
	#pragma unused(sender)
	#pragma unused(device)

	NSLog(@"Gamepad was unplugged");
}

void OSXHIDAction(void* context, IOReturn result, void* sender, IOHIDValueRef value)
{
	#pragma unused(result)
	#pragma unused(sender)

	// NOTE(jeff): Check suggested by Filip to prevent an access violation when
	// using a PS3 controller.
	// TODO(jeff): Investigate this further...
	if (IOHIDValueGetLength(value) > 2)
	{
		//NSLog(@"OSXHIDAction: value length > 2: %ld", IOHIDValueGetLength(value));
		return;
	}

	IOHIDElementRef element = IOHIDValueGetElement(value);
	if (CFGetTypeID(element) != IOHIDElementGetTypeID())
	{
		return;
	}

	//IOHIDElementCookie cookie = IOHIDElementGetCookie(element);
	//IOHIDElementType type = IOHIDElementGetType(element);
	//CFStringRef name = IOHIDElementGetName(element);
	int usagePage = IOHIDElementGetUsagePage(element);
	int usage = IOHIDElementGetUsage(element);

	CFIndex elementValue = IOHIDValueGetIntegerValue(value);

	// NOTE(jeff): This is the pointer back to our view
	HandmadeView* view = (__bridge HandmadeView*)context;

	// NOTE(jeff): This is just for reference. From the USB HID Usage Tables spec:
	// Usage Pages:
	//   1 - Generic Desktop (mouse, joystick)
	//   2 - Simulation Controls
	//   3 - VR Controls
	//   4 - Sports Controls
	//   5 - Game Controls
	//   6 - Generic Device Controls (battery, wireless, security code)
	//   7 - Keyboard/Keypad
	//   8 - LED
	//   9 - Button
	//   A - Ordinal
	//   B - Telephony
	//   C - Consumer
	//   D - Digitizers
	//  10 - Unicode
	//  14 - Alphanumeric Display
	//  40 - Medical Instrument

	if (usagePage == 1) // Generic Desktop Page
	{
		int hatDelta = 16;

		NSNumber* key = [NSNumber numberWithLong:((usagePage << 16) | usage)];
		HandmadeHIDElement* e = [view->_elementDictionary objectForKey:key];

		float normalizedValue = 0.0;
		if (e->max != e->min)
		{
			normalizedValue = (float)(elementValue - e->min) / (float)(e->max - e->min);
		}
		float scaledMin = -25.0;
		float scaledMax = 25.0;

		int scaledValue = scaledMin + normalizedValue * (scaledMax - scaledMin);

		//printf("page:usage = %d:%d  value = %ld  ", usagePage, usage, elementValue);
		switch(usage)
		{
			case 0x30: // x
				view->_hidX = scaledValue;
				//printf("[x] scaled = %d\n", view->_hidX);
				break;

			case 0x31: // y
				view->_hidY = scaledValue;
				//printf("[y] scaled = %d\n", view->_hidY);
				break;

			case 0x32: // z
				//view->_hidX = scaledValue;
				//printf("[z] scaled = %d\n", view->_hidX);
				break;

			case 0x35: // rz
				//view->_hidY = scaledValue;
				//printf("[rz] scaled = %d\n", view->_hidY);
				break;

			case 0x39: // Hat 0 = up, 2 = right, 4 = down, 6 = left, 8 = centered
			{
				printf("[hat] ");
				switch(elementValue)
				{
					case 0:
						view->_hidX = 0;
						view->_hidY = -hatDelta;
						printf("n\n");
						break;

					case 1:
						view->_hidX = hatDelta;
						view->_hidY = -hatDelta;
						printf("ne\n");
						break;

					case 2:
						view->_hidX = hatDelta;
						view->_hidY = 0;
						printf("e\n");
						break;

					case 3:
						view->_hidX = hatDelta;
						view->_hidY = hatDelta;
						printf("se\n");
						break;

					case 4:
						view->_hidX = 0;
						view->_hidY = hatDelta;
						printf("s\n");
						break;

					case 5:
						view->_hidX = -hatDelta;
						view->_hidY = hatDelta;
						printf("sw\n");
						break;

					case 6:
						view->_hidX = -hatDelta;
						view->_hidY = 0;
						printf("w\n");
						break;

					case 7:
						view->_hidX = -hatDelta;
						view->_hidY = -hatDelta;
						printf("nw\n");
						break;

					case 8:
						view->_hidX = 0;
						view->_hidY = 0;
						printf("up\n");
						break;
				}

			} break;

			default:
				//NSLog(@"Gamepad Element: %@  Type: %d  Page: %d  Usage: %d  Name: %@  Cookie: %i  Value: %ld  _hidX: %d",
				//      element, type, usagePage, usage, name, cookie, elementValue, view->_hidX);
				break;
		}
	}
	else if (usagePage == 7) // Keyboard
	{
		// NOTE(jeff): usages 0-3:
		//   0 - Reserved
		//   1 - ErrorRollOver
		//   2 - POSTFail
		//   3 - ErrorUndefined
		// Ignore them for now...
		if (usage < 4) return;

		if (![[view window] isKeyWindow])
		{
			// NOTE(jeff): Don't process keystrokes meant for other windows...
			return;
		}

		NSString* keyName = @"";

		// TODO(jeff): Store the keyboard events somewhere...

		bool isDown = elementValue;
		game_controller_input* controller = GetController(&view->_currentInput, 0);

		switch(usage)
		{
			case kHIDUsage_KeyboardW:
				keyName = @"w";
				OSXProcessKeyboardMessage(&controller->MoveUp, isDown);
				break;

			case kHIDUsage_KeyboardA:
				keyName = @"a";
				OSXProcessKeyboardMessage(&controller->MoveLeft, isDown);
				break;

			case kHIDUsage_KeyboardS:
				keyName = @"s";
				OSXProcessKeyboardMessage(&controller->MoveDown, isDown);
				break;

			case kHIDUsage_KeyboardD:
				keyName = @"d";
				OSXProcessKeyboardMessage(&controller->MoveRight, isDown);
				break;

			case kHIDUsage_KeyboardQ:
				keyName = @"q";
				OSXProcessKeyboardMessage(&controller->LeftShoulder, isDown);
				break;

			case kHIDUsage_KeyboardE:
				keyName = @"e";
				OSXProcessKeyboardMessage(&controller->RightShoulder, isDown);
				break;

			case kHIDUsage_KeyboardSpacebar:
				keyName = @"Space";
				OSXProcessKeyboardMessage(&controller->Start, isDown);
				break;

			case kHIDUsage_KeyboardEscape:
				keyName = @"ESC";
				OSXProcessKeyboardMessage(&controller->Back, isDown);
				break;

			case kHIDUsage_KeyboardUpArrow:
				keyName = @"Up";
				OSXProcessKeyboardMessage(&controller->ActionUp, isDown);
				break;

			case kHIDUsage_KeyboardLeftArrow:
				keyName = @"Left";
				OSXProcessKeyboardMessage(&controller->ActionLeft, isDown);
				break;

			case kHIDUsage_KeyboardDownArrow:
				keyName = @"Down";
				OSXProcessKeyboardMessage(&controller->ActionDown, isDown);
				break;

			case kHIDUsage_KeyboardRightArrow:
				keyName = @"Right";
				OSXProcessKeyboardMessage(&controller->ActionRight, isDown);
				break;

#if HANDMADE_INTERNAL
			case kHIDUsage_KeyboardP:
				keyName = @"p";

				if (isDown)
				{
					// TODO(jeff): Implement global pause
					GlobalPause = !GlobalPause;
				}
				break;

			case kHIDUsage_KeyboardL:
				keyName = @"l";

				if (isDown)
				{
					if (view->_osxState.InputPlayingIndex == 0)
					{
						if (view->_osxState.InputRecordingIndex == 0)
						{
							OSXBeginRecordingInput(&view->_osxState, 1);
						}
						else
						{
							OSXEndRecordingInput(&view->_osxState);
							OSXBeginInputPlayback(&view->_osxState, 1);
						}
					}
					else
					{
						OSXEndInputPlayback(&view->_osxState);
					}
				}
				break;
#endif
			default:
				return;
				break;
		}
		if (elementValue == 1)
		{
			//NSLog(@"%@ pressed", keyName);
		}
		else if (elementValue == 0)
		{
			//NSLog(@"%@ released", keyName);
		}
	}
	else if (usagePage == 9) // Buttons
	{
		if (elementValue == 1)
		{
			view->_hidButtons[usage] = 1;
			NSLog(@"Button %d pressed", usage);
		}
		else if (elementValue == 0)
		{
			view->_hidButtons[usage] = 0;
			NSLog(@"Button %d released", usage);
		}
		else
		{
			//NSLog(@"Gamepad Element: %@  Type: %d  Page: %d  Usage: %d  Name: %@  Cookie: %i  Value: %ld  _hidX: %d",
			//	  element, type, usagePage, usage, name, cookie, elementValue, view->_hidX);
		}
	}
	else
	{
		//NSLog(@"Gamepad Element: %@  Type: %d  Page: %d  Usage: %d  Name: %@  Cookie: %i  Value: %ld  _hidX: %d",
		//	  element, type, usagePage, usage, name, cookie, elementValue, view->_hidX);
	}
}


@implementation HandmadeHIDElement

- (id)initWithType:(long)t usagePage:(long)p usage:(long)u min:(long)n max:(long)x
{
	self = [super init];

	if (!self) return nil;

	type = t;
	page = p;
	usage = u;
	min = n;
	max = x;

	return self;
}

@end



@implementation HandmadeView

-(void)setupGamepad
{
	_hidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);

	if (_hidManager)
	{
		// NOTE(jeff): We're asking for Joysticks, GamePads, Multiaxis Controllers
		// and Keyboards
		NSArray* criteria = @[ @{ [NSString stringWithUTF8String:kIOHIDDeviceUsagePageKey]:
									[NSNumber numberWithInt:kHIDPage_GenericDesktop],
								[NSString stringWithUTF8String:kIOHIDDeviceUsageKey]:
									[NSNumber numberWithInt:kHIDUsage_GD_Joystick]
								},
							@{ (NSString*)CFSTR(kIOHIDDeviceUsagePageKey):
									[NSNumber numberWithInt:kHIDPage_GenericDesktop],
								(NSString*)CFSTR(kIOHIDDeviceUsageKey):
									[NSNumber numberWithInt:kHIDUsage_GD_GamePad]
								},
							@{ (NSString*)CFSTR(kIOHIDDeviceUsagePageKey):
									[NSNumber numberWithInt:kHIDPage_GenericDesktop],
								(NSString*)CFSTR(kIOHIDDeviceUsageKey):
									[NSNumber numberWithInt:kHIDUsage_GD_MultiAxisController]
							   }
#if 1
							   ,
							@{ (NSString*)CFSTR(kIOHIDDeviceUsagePageKey):
									[NSNumber numberWithInt:kHIDPage_GenericDesktop],
								(NSString*)CFSTR(kIOHIDDeviceUsageKey):
									[NSNumber numberWithInt:kHIDUsage_GD_Keyboard]
							   }
#endif
							];

		// NOTE(jeff): These all return void, so no error checking...
		IOHIDManagerSetDeviceMatchingMultiple(_hidManager, (__bridge CFArrayRef)criteria);
		IOHIDManagerRegisterDeviceMatchingCallback(_hidManager, OSXHIDAdded, (__bridge void*)self);
		IOHIDManagerRegisterDeviceRemovalCallback(_hidManager, OSXHIDRemoved, (__bridge void*)self);
		IOHIDManagerScheduleWithRunLoop(_hidManager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

		if (IOHIDManagerOpen(_hidManager, kIOHIDOptionsTypeNone) == kIOReturnSuccess)
		{
			IOHIDManagerRegisterInputValueCallback(_hidManager, OSXHIDAction, (__bridge void*)self);
		}
		else
		{
			// TODO(jeff): Diagnostic
		}
	}
	else
	{
		// TODO(jeff): Diagnostic
	}
}



- (CVReturn)getFrameForTime:(const CVTimeStamp*)outputTime
{
	// NOTE(jeff): We'll probably use this outputTime later for more precise
	// drawing, but ignore it for now
	#pragma unused(outputTime)

	static bool shouldRenderThisFrame = true;

	if (_renderAtHalfSpeed && !shouldRenderThisFrame)
	{
		// skip this frame
	}
	else
	{
		@autoreleasepool
		{
			[self processFrameAndRunGameLogic:YES];
		}
	}

	shouldRenderThisFrame = !shouldRenderThisFrame;

    return kCVReturnSuccess;
}


// Renderer callback function
static CVReturn GLXViewDisplayLinkCallback(CVDisplayLinkRef displayLink,
                                           const CVTimeStamp* now,
                                           const CVTimeStamp* outputTime,
                                           CVOptionFlags inFlags,
                                           CVOptionFlags* outFlags,
                                           void* displayLinkContext)
{
	#pragma unused(displayLink)
	#pragma unused(now)
	#pragma unused(inFlags)
	#pragma unused(outFlags)

	HandmadeView* view = (__bridge HandmadeView*)displayLinkContext;

    CVReturn result = [view getFrameForTime:outputTime];
    
	if (view->_glFallbackMode)
	{
		glFlush();
	}

    return result;
}


#if HANDMADE_INTERNAL
#define logOpenGLErrors(l) internalLogOpenGLErrors(l)
#else
#define logOpenGLErrors(l) {} 
#endif

static void internalLogOpenGLErrors(const char* label)
{
	GLenum err = glGetError();
	const char* errString = "No error";

	while (err != GL_NO_ERROR)
	{
		switch(err)
		{
			case GL_INVALID_ENUM:
				errString = "Invalid Enum";
				break;

			case GL_INVALID_VALUE:
				errString = "Invalid Value";
				break;

			case GL_INVALID_OPERATION:
				errString = "Invalid Operation";
				break;

			case GL_INVALID_FRAMEBUFFER_OPERATION:
				errString = "Invalid Framebuffer Operation";
				break;

			case GL_OUT_OF_MEMORY:
				errString = "Out of Memory";
				break;

			case GL_STACK_UNDERFLOW:
				errString = "Stack Underflow";
				break;

			case GL_STACK_OVERFLOW:
				errString = "Stack Overflow";
				break;

			default:
				errString = "Unknown Error";
				break;
		}
		printf("glError on %s: %s\n", label, errString);

		err = glGetError();
	}
}


#if 0
internal PLATFORM_WORK_QUEUE_CALLBACK(DoWorkerWork)
{
    char Buffer[256];
    snprintf(Buffer, sizeof(Buffer), "Thread %lu: ------> %s\n", (long)pthread_self(), (char *)Data);
    printf("%s\n", Buffer);
}
#endif


float OSXGetSecondsElapsed(u64 Then, u64 Now)
{
	static mach_timebase_info_data_t tb;

	u64 Elapsed = Now - Then;

	if (tb.denom == 0)
	{
		// First time we need to get the timebase
		mach_timebase_info(&tb);
	}

	//Nanoseconds Nanos = AbsoluteToNanoseconds(*((AbsoluteTime*)&Elapsed));
	//float Result = (float)UnsignedWideToUInt64(Nanos) * 1.0E-9;

	u64 Nanos = Elapsed * tb.numer / tb.denom;
	float Result = (float)Nanos * 1.0E-9;

	return Result;
}


- (void)setup
{
	if (_setupComplete)
	{
		return;
	}

	OSXMakeQueue(&_highPriorityQueue, 6);
	OSXMakeQueue(&_lowPriorityQueue, 2);


	_renderAtHalfSpeed = true;

	NSFileManager* FileManager = [NSFileManager defaultManager];
	NSString* AppPath = [NSString stringWithFormat:@"%@/Contents/Resources",
		[[NSBundle mainBundle] bundlePath]];
	if ([FileManager changeCurrentDirectoryPath:AppPath] == NO)
	{
		Assert(0);
	}

	// Get the conversion factor for doing profile timing with mach_absolute_time()
	mach_timebase_info_data_t timebase;
	mach_timebase_info(&timebase);
	_machTimebaseConversionFactor = (double)timebase.numer / (double)timebase.denom;


	// TODO(jeff): Remove this
	_elementDictionary = [[NSMutableDictionary alloc] init];


	///////////////////////////////////////////////////////////////////
	// Get the game shared library paths

	OSXGetAppFilename(&_osxState);

	OSXBuildAppPathFilename(&_osxState, (char*)"libhandmade.dylib",
	                        sizeof(_sourceGameCodeDLFullPath), _sourceGameCodeDLFullPath);

	// NOTE(jeff): We don't have to create a temp file
	_game = OSXLoadGameCode(_sourceGameCodeDLFullPath);


	///////////////////////////////////////////////////////////////////
	// Set up memory

#if HANDMADE_INTERNAL
	char* RequestedAddress = (char*)Gigabytes(8);
	uint32 AllocationFlags = MAP_PRIVATE|MAP_ANON|MAP_FIXED;
#else
	char* RequestedAddress = (char*)0;
	uint32 AllocationFlags = MAP_PRIVATE|MAP_ANON;
#endif

	_gameMemory.PermanentStorageSize = Megabytes(256); //Megabytes(256);
	_gameMemory.TransientStorageSize = Gigabytes(1); //Gigabytes(1);
	_gameMemory.DebugStorageSize = Megabytes(256); //Megabytes(64);

	_osxState.TotalSize = _gameMemory.PermanentStorageSize +
	                      _gameMemory.TransientStorageSize +
	                      _gameMemory.DebugStorageSize;


#ifndef HANDMADE_USE_VM_ALLOCATE
	// NOTE(jeff): I switched to mmap as the default, so unless the above
	// HANDMADE_USE_VM_ALLOCATE is defined in the build/make process,
	// we'll use the mmap version.

	_osxState.GameMemoryBlock = mmap(RequestedAddress, _osxState.TotalSize,
	                                 PROT_READ|PROT_WRITE,
	                                 AllocationFlags,
	                                 -1, 0);
	if (_osxState.GameMemoryBlock == MAP_FAILED)
	{
		printf("mmap error: %d  %s", errno, strerror(errno));
	}

	//memset(_osxState.GameMemoryBlock, 0, _osxState.TotalSize);
#else
	kern_return_t result = vm_allocate((vm_map_t)mach_task_self(),
									   (vm_address_t*)&_osxState.GameMemoryBlock,
									   _osxState.TotalSize,
									   VM_FLAGS_ANYWHERE);
	if (result != KERN_SUCCESS)
	{
		// TODO(jeff): Diagnostic
		NSLog(@"Error allocating memory");
	}
#endif

	_gameMemory.PermanentStorage = _osxState.GameMemoryBlock;
	_gameMemory.TransientStorage = ((uint8*)_gameMemory.PermanentStorage
								   + _gameMemory.PermanentStorageSize);
	_gameMemory.DebugStorage = (u8*)_gameMemory.TransientStorage +
								_gameMemory.TransientStorageSize;

	_gameMemory.HighPriorityQueue = &_highPriorityQueue;
	_gameMemory.LowPriorityQueue = &_lowPriorityQueue;

	_gameMemory.PlatformAPI.AddEntry = OSXAddEntry;
	_gameMemory.PlatformAPI.CompleteAllWork = OSXCompleteAllWork;

	_gameMemory.PlatformAPI.GetAllFilesOfTypeBegin = OSXGetAllFilesOfTypeBegin;
	_gameMemory.PlatformAPI.GetAllFilesOfTypeEnd = OSXGetAllFilesOfTypeEnd;
	_gameMemory.PlatformAPI.OpenNextFile = OSXOpenNextFile;
	_gameMemory.PlatformAPI.ReadDataFromFile = OSXReadDataFromFile;
	_gameMemory.PlatformAPI.FileError = OSXFileError;

	_gameMemory.PlatformAPI.AllocateMemory = OSXAllocateMemory;
	_gameMemory.PlatformAPI.DeallocateMemory = OSXDeallocateMemory;

#if HANDMADE_INTERNAL
	_gameMemory.PlatformAPI.DEBUGFreeFileMemory = DEBUGPlatformFreeFileMemory;
	_gameMemory.PlatformAPI.DEBUGReadEntireFile = DEBUGPlatformReadEntireFile;
	_gameMemory.PlatformAPI.DEBUGWriteEntireFile = DEBUGPlatformWriteEntireFile;

	_gameMemory.PlatformAPI.DEBUGExecuteSystemCommand = DEBUGExecuteSystemCommand;
	_gameMemory.PlatformAPI.DEBUGGetProcessState = DEBUGGetProcessState;
#endif

	///////////////////////////////////////////////////////////////////
	// Set up replay buffers

	// TODO(jeff): The loop replay is broken. Disable for now...
#if 0

	for (int ReplayIndex = 0;
	     ReplayIndex < ArrayCount(_osxState.ReplayBuffers);
	     ++ReplayIndex)
	{
		osx_replay_buffer* ReplayBuffer = &_osxState.ReplayBuffers[ReplayIndex];

		OSXGetInputFileLocation(&_osxState, false, ReplayIndex,
		                        sizeof(ReplayBuffer->Filename), ReplayBuffer->Filename);

		ReplayBuffer->FileHandle = open(ReplayBuffer->Filename, O_RDWR | O_CREAT | O_TRUNC, 0644);

		if (ReplayBuffer->FileHandle != -1)
		{
			int Result = ftruncate(ReplayBuffer->FileHandle, _osxState.TotalSize);

			if (Result != 0)
			{
				printf("ftruncate error on ReplayBuffer[%d]: %d: %s\n",
				       ReplayIndex, errno, strerror(errno));
			}

			ReplayBuffer->MemoryBlock = mmap(0, _osxState.TotalSize,
			                                 PROT_READ|PROT_WRITE,
			                                 MAP_PRIVATE,
			                                 ReplayBuffer->FileHandle,
			                                 0);

			if (ReplayBuffer->MemoryBlock != MAP_FAILED)
			{
#if 0
				fstore_t fstore = {};
				fstore.fst_flags = F_ALLOCATECONTIG;
				fstore.fst_posmode = F_PEOFPOSMODE;
				fstore.fst_offset = 0;
				fstore.fst_length = _osxState.TotalSize;

				int Result = fcntl(ReplayBuffer->FileHandle, F_PREALLOCATE, &fstore);

				if (Result != -1)
				{
					Result = ftruncate(ReplayBuffer->FileHandle, _osxState.TotalSize);

					if (Result != 0)
					{
						printf("ftruncate error on ReplayBuffer[%d]: %d: %s\n",
						       ReplayIndex, errno, strerror(errno));
					}
				}
				else
				{
					printf("fcntl error on ReplayBuffer[%d]: %d: %s\n",
					       ReplayIndex, errno, strerror(errno));
				}

				//memset(ReplayBuffer->MemoryBlock, 0, _osxState.TotalSize);
				//memset(ReplayBuffer->MemoryBlock, 0, _osxState.TotalSize);
				//memcpy(ReplayBuffer->MemoryBlock, 0, _osxState.TotalSize);
#else
				// NOTE(jeff): Tried out Filip's lseek suggestion to see if
				// it is any faster than ftruncate. Seems about the same.
				off_t SeekOffset = lseek(ReplayBuffer->FileHandle, _osxState.TotalSize - 1, SEEK_SET);

				if (SeekOffset)
				{
					int BytesWritten = write(ReplayBuffer->FileHandle, "", 1);

					if (BytesWritten != 1)
					{
						printf("Error writing to lseek offset of ReplayBuffer[%d]: %d: %s\n",
							   ReplayIndex, errno, strerror(errno));
					}
				}
#endif
			}
			else
			{
				printf("mmap error on ReplayBuffer[%d]: %d  %s",
				       ReplayIndex, errno, strerror(errno));
			}
		}
		else
		{
			printf("Error creating ReplayBuffer[%d] file %s: %d : %s\n",
					ReplayIndex, ReplayBuffer->Filename, errno, strerror(errno));
		}
	}

#endif

	///////////////////////////////////////////////////////////////////
	// Set up input

	_newInput = &_input[0];
	_oldInput = &_input[1];


	///////////////////////////////////////////////////////////////////
	// Set up view resizing and OpenGL

	[self setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    NSOpenGLPixelFormatAttribute attrs[] =
    {
        NSOpenGLPFAAccelerated,
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFADepthSize, 24,
        //NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion3_2Core,
        0
    };

    NSOpenGLPixelFormatAttribute fallbackAttrs[] =
    {
        NSOpenGLPFADepthSize, 24,
        //NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion3_2Core,
        0
    };

	_glFallbackMode = NO;
    NSOpenGLPixelFormat* pf = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];

    if (pf == nil)
    {
        printf("Error creating OpenGLPixelFormat with accelerated attributes...trying fallback attributes\n");

		pf = [[NSOpenGLPixelFormat alloc] initWithAttributes:fallbackAttrs];

		if (pf == nil)
		{
			printf("Error creating OpenGLPixelFormat with fallback attributes\n");
		}
		else
		{
			_glFallbackMode = YES;
		}
    }


    NSOpenGLContext* context = [[NSOpenGLContext alloc] initWithFormat:pf shareContext:nil];
    if (context == nil)
	{
		printf("Error creating NSOpenGLContext\n");
	}

    [self setPixelFormat:pf];
    [self setOpenGLContext:context];

	_fullScreenOptions = [NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES]
													 forKey:NSFullScreenModeSetting];

	/* NOTE(casey): 1080p display mode is 1920x1080 -> Half of that is 960x540
	                1920 -> 2048 = 2048-1920 -> 128 pixels
	                1080 -> 2048 = 2048-1080 -> pixels 968
	                1024 + 128 = 1152
	*/

	int BytesPerPixel = 4;
	//_renderBuffer.Width = 960; // 1920;
	//_renderBuffer.Height = 540; // 1080;
	_renderBuffer.Width = 960;
	_renderBuffer.Height = 540;

	_renderBuffer.Pitch = Align16(_renderBuffer.Width * BytesPerPixel);
	int BitmapMemorySize = (_renderBuffer.Pitch * _renderBuffer.Height);
	_renderBuffer.Memory = mmap(0,
								BitmapMemorySize,
	                            PROT_READ | PROT_WRITE,
	                            MAP_PRIVATE | MAP_ANON,
	                            -1,
	                            0);

	if (_renderBuffer.Memory == MAP_FAILED)
	{
		printf("Render Buffer Memory mmap error: %d  %s", errno, strerror(errno));
	}

	[self setupGamepad];


	//_soundOutput.Frequency = 800.0;
	_soundOutput.SoundBuffer.SamplesPerSecond = 48000;
	_soundOutput.SoundBufferSize = _soundOutput.SoundBuffer.SamplesPerSecond * sizeof(int16) * 2;

	u32 MaxPossibleOverrun = 8 * 2 * sizeof(int16);

	_soundOutput.SoundBuffer.Samples = (int16*)mmap(0, _soundOutput.SoundBufferSize + MaxPossibleOverrun,
											PROT_READ|PROT_WRITE,
											MAP_PRIVATE | MAP_ANON,
											-1,
											0);
	if (_soundOutput.SoundBuffer.Samples == MAP_FAILED)
	{
		printf("Sound Buffer Samples mmap error: %d  %s", errno, strerror(errno));
	}
	memset(_soundOutput.SoundBuffer.Samples, 0, _soundOutput.SoundBufferSize);

	_soundOutput.CoreAudioBuffer = (int16*)mmap(0, _soundOutput.SoundBufferSize + MaxPossibleOverrun,
										PROT_READ|PROT_WRITE,
										MAP_PRIVATE | MAP_ANON,
										-1,
										0);
	if (_soundOutput.CoreAudioBuffer == MAP_FAILED)
	{
		printf("Core Audio Buffer mmap error: %d  %s", errno, strerror(errno));
	}
	memset(_soundOutput.CoreAudioBuffer, 0, _soundOutput.SoundBufferSize);

	_soundOutput.ReadCursor = _soundOutput.CoreAudioBuffer;
	_soundOutput.WriteCursor = _soundOutput.CoreAudioBuffer;

	OSXInitCoreAudio(&_soundOutput);

	_lastCounter = mach_absolute_time();

	_setupComplete = YES;
}


- (id)init
{
	self = [super init];

	if (self == nil)
	{
		return nil;
	}

	[self setup];

	return self;
}


- (void)awakeFromNib
{
	[self setup];
}


- (void)prepareOpenGL
{
	glGetError();

	[super prepareOpenGL];

	[[self openGLContext] makeCurrentContext];

	// NOTE(jeff): Use the vertical refresh rate to sync buffer swaps
	GLint swapInt = 1;
	[[self openGLContext] setValues:&swapInt forParameter:NSOpenGLCPSwapInterval];

	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	logOpenGLErrors("glPixelStorei");

	glGenTextures(1, &_textureId);
	logOpenGLErrors("glGenTextures");

	glBindTexture(GL_TEXTURE_2D, _textureId);
	logOpenGLErrors("glBindTexture");

	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, _renderBuffer.Width, _renderBuffer.Height,
				 0, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, NULL);
	logOpenGLErrors("glTexImage2D");

	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	logOpenGLErrors("glTexParameteri");
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	logOpenGLErrors("glTexParameteri");
	glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE /*GL_MODULATE*/);
	logOpenGLErrors("glTexEnvi");

	CVReturn cvreturn = CVDisplayLinkCreateWithActiveCGDisplays(&_displayLink);
	if (cvreturn != kCVReturnSuccess)
	{
		printf("Error in CVDisplayLinkCreateWithActiveCGDisplays(): %d\n", cvreturn);
	}

	cvreturn = CVDisplayLinkSetOutputCallback(_displayLink, &GLXViewDisplayLinkCallback, (__bridge void *)(self));
	if (cvreturn != kCVReturnSuccess)
	{
		printf("Error in CVDisplayLinkSetOutputCallback(): %d\n", cvreturn);
	}

	CGLContextObj cglContext = static_cast<CGLContextObj>([[self openGLContext] CGLContextObj]);
	CGLPixelFormatObj cglPixelFormat = static_cast<CGLPixelFormatObj>([[self pixelFormat] CGLPixelFormatObj]);
	cvreturn = CVDisplayLinkSetCurrentCGDisplayFromOpenGLContext(_displayLink, cglContext, cglPixelFormat);
	if (cvreturn != kCVReturnSuccess)
	{
		printf("Error in CVDisplayLinkSetCurrentCGDisplayFromOpenGLContext(): %d\n", cvreturn);
	}
	
	CVTime cvtime = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(_displayLink);
	_targetSecondsPerFrame = (double)cvtime.timeValue / (double)cvtime.timeScale;
	_targetFramesPerSecond = (double)cvtime.timeScale / (double)cvtime.timeValue + 0.5;

	if (_renderAtHalfSpeed)
	{
		_targetSecondsPerFrame += _targetSecondsPerFrame;
		_targetFramesPerSecond /= 2;
	}

	printf("targetSecondsPerFrame: %f\n", _targetSecondsPerFrame);
	printf("Target frames per second = %d\n", _targetFramesPerSecond);

	cvreturn = CVDisplayLinkStart(_displayLink);
	if (cvreturn != kCVReturnSuccess)
	{
		printf("Error in CVDisplayLinkStart(): %d\n", cvreturn);
	}
}


#if 0
internal void
HandleDebugCycleCounters(game_memory *Memory)
{

#if HANDMADE_INTERNAL
    printf("DEBUG CYCLE COUNTS:\n");
    for(int CounterIndex = 0;
        CounterIndex < ArrayCount(Memory->Counters);
        ++CounterIndex)
    {
        debug_cycle_counter *Counter = Memory->Counters + CounterIndex;

        if(Counter->HitCount)
        {
            char TextBuffer[256];
            snprintf(TextBuffer, sizeof(TextBuffer),
                     "  %d: %llucy %uh %llucy/h\n",
                     CounterIndex,
                     Counter->CycleCount,
                     Counter->HitCount,
                     Counter->CycleCount / Counter->HitCount);
            printf("%s", TextBuffer);
            Counter->HitCount = 0;
            Counter->CycleCount = 0;
        }
    }
#endif

}
#endif


- (void)reshape
{
	[super reshape];

	[self processFrameAndRunGameLogic:NO];
}


#if HANDMADE_INTERNAL
global_variable debug_table GlobalDebugTable_;
debug_table* GlobalDebugTable = &GlobalDebugTable_;
#endif

- (void)processFrameAndRunGameLogic:(BOOL)runGameLogicFlag
{
	// NOTE(jeff): Drawing is normally done on a background thread via CVDisplayLink.
	// When the window/view is resized, reshape is called automatically on the
	// main thread, so lock the context from simultaneous access during a resize.

	u64 CurrentTime = mach_absolute_time();

	_lastCounter = CurrentTime;

	// TODO(jeff): Tighten up this GLContext lock
	CGLLockContext(static_cast<CGLContextObj>([[self openGLContext] CGLContextObj]));


	if (!runGameLogicFlag)
	{
		// NOTE(jeff): Don't run the game update logic during resize events
		NSRect rect = [self bounds];

		glDisable(GL_DEPTH_TEST);
		glLoadIdentity();
		glViewport(0, 0, rect.size.width, rect.size.height);
	}
	else
	{
		// NOTE(jeff): Not a resize, so run game logic and render the next frame

		//
		//
		//

		BEGIN_BLOCK(ExecutableRefresh);

		_newInput->dtForFrame = _targetSecondsPerFrame;

		///////////////////////////////////////////////////////////////////
		// Check for updated game code

		//_newInput->ExecutableReloaded = false;
		_gameMemory.ExecutableReloaded = false;

		time_t NewDLWriteTime = OSXGetLastWriteTime(_sourceGameCodeDLFullPath);
		if (NewDLWriteTime != _game.DLLastWriteTime)
		{
			OSXCompleteAllWork(&_highPriorityQueue);
			OSXCompleteAllWork(&_lowPriorityQueue);

#if HANDMADE_INTERNAL
			GlobalDebugTable = &GlobalDebugTable_;
#endif

			OSXUnloadGameCode(&_game);
			_game = OSXLoadGameCode(_sourceGameCodeDLFullPath);
			//_newInput->ExecutableReloaded = true;
			_gameMemory.ExecutableReloaded = true;
		}
		END_BLOCK(ExecutableRefresh);

		//
		//
		//

		BEGIN_BLOCK(InputProcessing);

		//game_controller_input* OldKeyboardController = GetController(_oldInput, 0);
		game_controller_input* OldKeyboardController = GetController(&_currentInput, 0);

		game_controller_input* NewKeyboardController = GetController(_newInput, 0);
		memset(NewKeyboardController, 0, sizeof(game_controller_input));
		NewKeyboardController->IsConnected = true;
		for (int ButtonIndex = 0;
		     ButtonIndex < ArrayCount(NewKeyboardController->Buttons);
		     ++ButtonIndex)
		{
			NewKeyboardController->Buttons[ButtonIndex].EndedDown = 
				OldKeyboardController->Buttons[ButtonIndex].EndedDown;
		}


		if (NewKeyboardController->Start.EndedDown)
		{
			printf("Start ended down\n");
		}


		// TODO(jeff): Fix this for multiple controllers
		//Win32ProcessPendingMessages(&Win32State, NewKeyboardController);

		//game_controller_input* OldController = &_oldInput->Controllers[0];
		game_controller_input* NewController = &_newInput->Controllers[0];

		NewController->IsConnected = true;
		NewController->StickAverageX = _hidX;
		NewController->StickAverageY = _hidY;

		NewController->ActionDown.EndedDown = _currentInput.Controllers[0].ActionDown.EndedDown;
		NewController->ActionUp.EndedDown = _currentInput.Controllers[0].ActionUp.EndedDown;
		NewController->ActionLeft.EndedDown = _currentInput.Controllers[0].ActionLeft.EndedDown;
		NewController->ActionRight.EndedDown = _currentInput.Controllers[0].ActionRight.EndedDown;

		NewController->MoveUp.EndedDown = _currentInput.Controllers[0].MoveUp.EndedDown;
		NewController->MoveDown.EndedDown = _currentInput.Controllers[0].MoveDown.EndedDown;
		NewController->MoveLeft.EndedDown = _currentInput.Controllers[0].MoveLeft.EndedDown;
		NewController->MoveRight.EndedDown = _currentInput.Controllers[0].MoveRight.EndedDown;

		_newInput->dtForFrame = _targetSecondsPerFrame;

		NSPoint PointInScreen = [NSEvent mouseLocation];

		BOOL mouseInWindow = NSPointInRect(PointInScreen, self.window.frame);

		if (mouseInWindow)
		{
			// NOTE(jeff): Use this instead of convertRectFromScreen: if you want to support Snow Leopard
			// NSPoint PointInWindow = [[self window] convertScreenToBase:[NSEvent mouseLocation]];

			NSRect RectInWindow = [[self window] convertRectFromScreen:NSMakeRect(PointInScreen.x, PointInScreen.y, 1, 1)];
			NSPoint PointInWindow = RectInWindow.origin;
			NSPoint PointInView = [self convertPoint:PointInWindow fromView:nil];

			//_newInput->MouseX = (-0.5f * (r32)_renderBuffer.Width + 0.5f) + (r32)PointInView.x;
			//_newInput->MouseY = (-0.5f * (r32)_renderBuffer.Height + 0.5f) + (r32)PointInView.y;
			_newInput->MouseX = (r32)PointInView.x;
			//_newInput->MouseY = (r32)((_renderBuffer.Height - 1) - PointInView.y);
			_newInput->MouseY = (r32)PointInView.y;
		
			_newInput->MouseZ = 0; // TODO(casey): Support mousewheel?

			NSUInteger ButtonMask = [NSEvent pressedMouseButtons];

			for (u32 ButtonIndex = 0;
				 ButtonIndex < PlatformMouseButton_Count;
				 ++ButtonIndex)
			{
				u32 IsDown = 0;

				if (ButtonIndex > 0)
				{
					IsDown = (ButtonMask >> ButtonIndex) & 0x0001;
				}
				else
				{
					IsDown = ButtonMask & 0x0001;
				}

				// NOTE(jeff): On OS X, Mouse Button 1 is Right, 2 is Middle
				u32 MouseButton = ButtonIndex;
				if (ButtonIndex == 1) MouseButton = PlatformMouseButton_Right;
				else if (ButtonIndex == 2) MouseButton = PlatformMouseButton_Middle;

				_newInput->MouseButtons[MouseButton] = _oldInput->MouseButtons[MouseButton];
				_newInput->MouseButtons[MouseButton].HalfTransitionCount = 0;

#if 0
				_newInput->MouseButtons[MouseButton].EndedDown = ButtonClicked;
				_newInput->MouseButtons[MouseButton].HalfTransitionCount = 0;

				if (ButtonClicked)
				{
					++_newInput->MouseButtons[MouseButton].HalfTransitionCount;
					printf("Mouse Button %d was clicked at (%f, %f)\n", ButtonIndex, _newInput->MouseX, _newInput->MouseY);
				}
#else
				OSXProcessKeyboardMessage(&_newInput->MouseButtons[MouseButton], IsDown);
#endif
			}
		}
		else
		{
			_newInput->MouseX = _oldInput->MouseX;
			_newInput->MouseY = _oldInput->MouseY;
			_newInput->MouseZ = _oldInput->MouseZ;
		}

		int ModifierFlags = [[NSApp currentEvent] modifierFlags];
		_newInput->ShiftDown = (ModifierFlags & NSShiftKeyMask);
		_newInput->AltDown = (ModifierFlags & NSAlternateKeyMask);
		_newInput->ControlDown = (ModifierFlags & NSControlKeyMask);

#if 0
		if (ModifierFlags & NSShiftKeyMask)
		{
			printf("Shift Key is down\n");
		}
		if (ModifierFlags & NSAlternateKeyMask)
		{
			printf("Alt Key is down\n");
		}
		if (ModifierFlags & NSCommandKeyMask)
		{
			printf("Command Key is down\n");
		}
		if (ModifierFlags & NSControlKeyMask)
		{
			printf("Control Key is down\n");
		}
#endif

#if 0
		// NOTE(jeff): Support for multiple controllers here...

		#define HID_MAX_COUNT 5

		uint32 MaxControllerCount = HID_MAX_COUNT;
		if (MaxControllerCount > (ArrayCount(_newInput->Controllers) - 1))
		{
			MaxControllerCount = (ArrayCount(_newInput->Controllers) - 1);
		}

		for (uint32 ControllerIndex = 0; ControllerIndex < MaxControllerCount; ++ControllerIndex)
		{
			// NOTE(jeff): index 0 is the keyboard
			uint32 OurControllerIndex = ControllerIndex + 1;
			game_controller_input* OldController = GetController(_oldInput, OurControllerIndex);
			game_controller_input* NewController = GetController(_newInput, OurControllerIndex);
		}
#endif

		END_BLOCK(InputProcessing);

		//
		//
		//

		BEGIN_BLOCK(GameUpdate);

		if (!GlobalPause)
		{
			if (_osxState.InputRecordingIndex)
			{
				OSXRecordInput(&_osxState, _newInput);
			}

			if (_osxState.InputPlayingIndex)
			{
				game_input Temp = *_newInput;

				OSXPlaybackInput(&_osxState, _newInput);

				for (u32 MouseButtonIndex = 0;
					 MouseButtonIndex < PlatformMouseButton_Count;
					 ++MouseButtonIndex)
				{
					_newInput->MouseButtons[MouseButtonIndex] = Temp.MouseButtons[MouseButtonIndex];
				}
				_newInput->MouseX = Temp.MouseX;
				_newInput->MouseY = Temp.MouseY;
				_newInput->MouseZ = Temp.MouseZ;
			}

			if (_game.UpdateAndRender)
			{
				_game.UpdateAndRender(&_gameMemory, _newInput, &_renderBuffer);

				//HandleDebugCycleCounters(&_gameMemory);
			}
		}

		END_BLOCK(GameUpdate);

		//
		//
		//

		BEGIN_BLOCK(AudioUpdate);

		if (!GlobalPause)
		{
			// TODO(jeff): Move this into the sound render code
			//_soundOutput.Frequency = 440.0 + (15 * _hidY);

			if (_game.GetSoundSamples)
			{
				// Sample Count is SamplesPerSecond / GameRefreshRate
				//_soundOutput.SoundBuffer.SampleCount = 1600; // (48000samples/sec) / (30fps)
				// ^^^ calculate this. We might be running at 30 or 60 fps
				_soundOutput.SoundBuffer.SampleCount = _soundOutput.SoundBuffer.SamplesPerSecond / _targetFramesPerSecond;

				_game.GetSoundSamples(&_gameMemory, &_soundOutput.SoundBuffer);

				int16* CurrentSample = _soundOutput.SoundBuffer.Samples;
				for (int i = 0; i < _soundOutput.SoundBuffer.SampleCount; ++i)
				{
					*_soundOutput.WriteCursor++ = *CurrentSample++;
					*_soundOutput.WriteCursor++ = *CurrentSample++;

					if ((char*)_soundOutput.WriteCursor >= ((char*)_soundOutput.CoreAudioBuffer + _soundOutput.SoundBufferSize))
					{
						//printf("Write cursor wrapped!\n");
						_soundOutput.WriteCursor  = _soundOutput.CoreAudioBuffer;
					}
				}

				// Prime the pump to get the write cursor out in front of the read cursor...
				static bool firstTime = true;

				if (firstTime)
				{
					firstTime = false;

					_game.GetSoundSamples(&_gameMemory, &_soundOutput.SoundBuffer);

					int16* CurrentSample = _soundOutput.SoundBuffer.Samples;
					for (int i = 0; i < _soundOutput.SoundBuffer.SampleCount; ++i)
					{
						*_soundOutput.WriteCursor++ = *CurrentSample++;
						*_soundOutput.WriteCursor++ = *CurrentSample++;

						if ((char*)_soundOutput.WriteCursor >= ((char*)_soundOutput.CoreAudioBuffer + _soundOutput.SoundBufferSize))
						{
							_soundOutput.WriteCursor  = _soundOutput.CoreAudioBuffer;
						}
					}
				}
			}
		}

		END_BLOCK(AudioUpdate);

		//
		//
		//

#if HANDMADE_INTERNAL
		BEGIN_BLOCK(DebugCollation);

		if (_game.DEBUGFrameEnd && runGameLogicFlag)
		{
			GlobalDebugTable = _game.DEBUGFrameEnd(&_gameMemory, _newInput, &_renderBuffer);
		}
		GlobalDebugTable_.EventArrayIndex_EventIndex = 0;

		END_BLOCK(DebugCollation);
#endif


		game_input* Temp = _newInput;
		_newInput = _oldInput;
		_oldInput = Temp;
	}


	///////////////////////////////////////////////////////////////////
	// Draw the latest frame to the screen

	BEGIN_BLOCK(FrameDisplay);

	[[self openGLContext] makeCurrentContext];

	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

	GLfloat vertices[] =
	{
		-1, -1, 0,
		-1, 1, 0,
		1, 1, 0,
		1, -1, 0,
	};

	/*
	GLfloat tex_coords[] =
	{
		0, 1,
		0, 0,
		1, 0,
		1, 1,
	};
	*/

	// Casey's renderer flips the Y-coords back around to "normal"
	GLfloat tex_coords[] =
	{
		0, 0,
		0, 1,
		1, 1,
		1, 0,
	};

    glVertexPointer(3, GL_FLOAT, 0, vertices);
    glTexCoordPointer(2, GL_FLOAT, 0, tex_coords);

    glEnableClientState(GL_VERTEX_ARRAY);
    glEnableClientState(GL_TEXTURE_COORD_ARRAY);

    glBindTexture(GL_TEXTURE_2D, _textureId);

    glEnable(GL_TEXTURE_2D);
	glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, _renderBuffer.Width, _renderBuffer.Height,
					GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, _renderBuffer.Memory);

    GLushort indices[] = { 0, 1, 2, 0, 2, 3 };
    glColor4f(1,1,1,1);
    glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, indices);
    glDisable(GL_TEXTURE_2D);

    glDisableClientState(GL_VERTEX_ARRAY);
    glDisableClientState(GL_TEXTURE_COORD_ARRAY);

    CGLFlushDrawable(static_cast<CGLContextObj>([[self openGLContext] CGLContextObj]));
    CGLUnlockContext(static_cast<CGLContextObj>([[self openGLContext] CGLContextObj]));

	END_BLOCK(FrameDisplay);

	//
	//
	//

	// TODO(jeff): FramerateWait block. Doesn't make sense to do it here as we
	//             are using CVDisplayLink

	u64 EndCounter = mach_absolute_time();
	FRAME_MARKER(OSXGetSecondsElapsed(_lastCounter, EndCounter));
	_lastCounter = EndCounter;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-missing-super-calls"
- (void)dealloc
{
	OSXStopCoreAudio(&_soundOutput);

	// NOTE(jeff): It's a good idea to stop the display link before
	// anything in the view is released. Otherwise, the display link
	// might try calling into the view for an update after the view's
	// memory is released.
    CVDisplayLinkStop(_displayLink);
    CVDisplayLinkRelease(_displayLink);

	printf("dealloc!\n");
    //[super dealloc];
}
#pragma clang diagnostic pop


- (void)toggleFullScreen:(id)sender
{
	#pragma unused(sender)

	if ([self isInFullScreenMode])
	{
		[self exitFullScreenModeWithOptions:_fullScreenOptions];
		[[self window] makeFirstResponder:self];
	}
	else
	{
		[self enterFullScreenMode:[NSScreen mainScreen]
					  withOptions:_fullScreenOptions];
	}
}


- (BOOL)acceptsFirstResponder
{
	return YES;
}


- (BOOL)becomeFirstResponder
{
	return  YES;
}


- (BOOL)resignFirstResponder
{
	return YES;
}


- (void)keyDown:(NSEvent*)event
{
	// NOTE(jeff): Eat the key event for now.
	// We're currently processing the key via HID.
	// We'll probably move it here to avoid needing
	// a hypothetical keyboard entitlement.

	switch ([event keyCode])
	{
		case 12:
			printf("QQQQQ!\n");
			break;
	}
}

@end


