CC = clang++
CFLAGS = -fobjc-arc -Wall -Wextra -std=c++11
FRAMEWORKS = -framework Cocoa -framework QuartzCore -framework IOSurface -framework Metal

all: ParentApp ChildProcess

ParentApp: parent.mm
	$(CC) $(CFLAGS) $(FRAMEWORKS) parent.mm -o ParentApp

ChildProcess: child.mm
	$(CC) $(CFLAGS) $(FRAMEWORKS) child.mm -o ChildProcess

clean:
	rm -f ParentApp ChildProcess

.PHONY: all clean
