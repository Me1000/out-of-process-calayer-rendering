# Cross process IOSurface example

I looked high and wide for an example of how to correctly use an IOSurface for cross process rendering.
Unfortunately IOSurfaces are poorly documented (which is sadly the case for most Apple APIs these days), and most
uses of them for multi-process rendering is buried in massive code-bases like Chrome or WebKit (which actually,
of course, uses private APIs all over the place).

As such, I figured I would open source this proof of concept implementation so that hopefully no one else has
to waste as much time as I did trying to figure out the right way to do it.

## Building
Just type `make` on your Mac and it should work. This was testing on MacOS Sonoma 14.6.1.
As of publishing this, the build completes with no errors or warnings.

## Child process
I'm using the posix_spawn API to spin up a child process, that should be relatively straight forward.

## IOSurfaces
IOSurfaces are just a wrapper around a shared memory buffer. You can have them back any CoreGraphics context
or Metal texture if you want.

Apple got rid of the ability to reference them globally, so sharing them with another process involves some
bootstrapping and handshaking between two processes. I go into that in the next section.

IOSurfaces can only be shared via Mach Messages, so trying to share them with any existing IPC system (e.g. pipes)
won't work.

## Mach Messages
The Mac's Mach Kernel uses Mach messages for most IPC calls. There exist a few higher level APIs, but I chose to
use the actual mach calls.

### How it works:
The parent process registers itself with the kernel with a named port that a child process can look up. This name
is a string `com.example.messageport` is what I used. Another process can use that same string to lookup the port
and send it messages. 

I'm using a light CFRunLoop wrapper to create a CFRunLoopSource for the port, that means that when the process gets
a mach message, it is dispatched to the run loop I specified (in this case, the main run loop on the thread). This makes
things simple since all the code is running on the main thread.

There are two message types the parent process expects to receive: the "setup" message that contains the buffers and the
"swap" messages which tell the process which surface it should use for rendering. These message structures are
defined in the `message-structures.h` file.

When the child process spins up it creates a multi-buffered backing to draw into. I chose 2 buffers but this code could
easily be adapted to support an arbitrary number of buffers if you wanted.

When the IOSurfaces are setup we create a mach port for them, and send a special mach message to the parent process, so 
that the parent process can lookup the IOSurfaces.

The child process creates a CoreAnimation layer tree and starts some animations. At a regular interval it renders the
layers into a graphics context that is backed by an IOSurface. When it finishes rendering it sends a message to the parent
process letting it know which surface to use for rendering.

On the parent process side we just keep processing these messages and updating the internal state. We use CALayer's `contents`
property to the current IOSurface in use, and CoreAnimation takes care of the rest.

## Double buffering
This repo has two real commit, the first is a working single buffered implementation that has all the problems
a single buffered rendering pipeline normally has, namely it flickers a bunch. But the implementation is obviously much
simpler.

In order to avoid flickering, I added double buffering support. The code is written so that it should be easy to support
as many buffers as you want (sometimes it's useful to use three). It round robins though the buffers, sending a message
to the parent process each time a rendering is done, letting the parent process know which surface is the most recent.

## Resource freeing
I'm basically never freeing any resources, so you should probably do that if you don't expect your surfaces/ports to live
for the duration of your program.


## Conclusion
I hope this code helps someone going forward. It's super self contained on purpose, and please check out the initial commit to
see a single buffered implementation. It's a bit different because the parent process no longer waits for the child process to
send an "update" message. But it flickers way too much if you're running any kind of animations.
 