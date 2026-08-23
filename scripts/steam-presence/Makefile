CC = x86_64-w64-mingw32-gcc
CFLAGS = -O2 -Wall -Wextra
TARGET := WhiskySteamPresence.exe
RESOURCES := ../../WhiskyKit/Sources/WhiskyKit/Steam/Resources

all: $(TARGET)

$(TARGET): presence.c
	$(CC) $(CFLAGS) -municode -mwindows -static -s -o $@ $<

install: $(TARGET)
	mkdir -p $(RESOURCES)
	cp $(TARGET) $(RESOURCES)/$(TARGET)

clean:
	rm -f $(TARGET)

.PHONY: all install clean
