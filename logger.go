package blog

import (
	"context"
	"encoding/binary"
	"fmt"
	"hash/crc32"
	"io"
	"math/bits"
	"runtime"
	"sync"
	"time"
)

const defaultPayloadLength = 1024

// A Logger records and serialize information about each call to its
// Log, Debug, Info, Warn, and Error methods and respective methods
// of [LoggerContext] taken with [Logger.With].
type Logger struct {
	wlock *sync.Mutex
	dst   io.Writer
	bufs  *sync.Pool

	logFrom      LoggingLevel
	logLocations bool
}

func (l *Logger) Trace(ctx context.Context, msg string, attrs ...Attr) {
	l.logLevel(ctx, LoggingLevelTrace, msg, 0, nil, attrs...)
}

// With returns a Logger that includes the given attributes
// in each output operation.
func (l *Logger) With(ctx ...Attr) LoggerContext {
	return LoggerContext{
		logger:  l,
		payload: make([]byte, 0, defaultPayloadLength),
	}
}

// logLevel logs record with given attributes with given level.
// locationSkip parameter is used for location retrieval.
//
// The following sequence will be written in the end:
//
//   - 0xFF
//   - CRC32 of record content (starting from time to the end).
//   - UVARINT(record_length)
//   - ----------------------
//   - Time (8 bytes)
//   - Level (1 byte)
//   - Location, either just 0 or UVARINT(file_name) file_name UVARINT(LINE)
//   - Message UVARING(message) message
//   - Payload built with [Logger.With].
//   - Serialized(attrs)
//
// [Logger.With] payload looks the same as its attributes would be in the head of attrs explicitly.
// So it is just concat.
func (l *Logger) logLevel(
	ctx context.Context,
	level LoggingLevel,
	msg string,
	locationSkip int,
	withPayload []byte,
	attrs ...Attr,
) {
	if level < l.logFrom {
		return
	}

	logData := l.bufs.Get().([]byte)[:0]

	// Omit the first 1 + 4 + 10 bytes as we store 0xff + CRC32 + uvarint(record_size) in here.
	// This uvarint part's length may differ, and we may need an adjustment to pack that header tightly.
	var record []byte
	if len(logData) < 15 {
		logData = make([]byte, 0, defaultPayloadLength)
	}
	record = logData[15:23]
	defer func() {
		l.bufs.Put(logData)
	}()

	// Now, put fields.

	// Time.
	// Is omitted for now.

	// Level.
	record = append(record, byte(level))

	// Location if needed. Will just put 0 if not needed. Will be uvarint(file) | uvarint(line) otherwise.
	if !l.logLocations {
		record = append(record, 0)
	} else {
		locationSkip = max(3, locationSkip)
		_, fn, line, ok := runtime.Caller(locationSkip)
		if ok {
			record = binary.AppendUvarint(record, uint64(len(fn)))
			record = append(record, fn...)
			record = binary.AppendUvarint(record, uint64(line))
		} else {
			// Failed to get caller info.
			record = append(record, 0)
		}
	}

	// Message
	record = binary.AppendUvarint(record, uint64(len(msg)))
	record = append(record, msg...)

	// With payload.
	record = append(record, withPayload...)

	// Serialize our attrs.
	// TODO

	// Get CRC32, adjust the placement, put header and get the data to write.
	checksum := crc32.Checksum(record[8:], crcTable)
	width := 5 + (bits.Len64(uint64(len(record)))+6)/7 // 0xFF + CRC + UVARINT(record.length)
	data := logData[15-width : 15-width]
	data = append(data, 0xff)

	l.wlock.Lock()
	defer l.wlock.Unlock()

	// Now put time. We need to do this AFTER a lock to keep a sequence of log events ordered in time.
	binary.LittleEndian.PutUint64(record, uint64(time.Now().UnixNano()))
	checksum = crc32.Update(checksum, crcTable, record[:8])
	data = binary.LittleEndian.AppendUint32(data, checksum)
	data = binary.AppendUvarint(data, uint64(len(record)))
	data = data[:width+len(record)]

	if _, err := l.dst.Write(data); err != nil {
		fmt.Println("failed to write logged data:", err)
	}
}

type LoggerContext struct {
	logger  *Logger
	payload []byte
}

type LoggingLevel uint8

const (
	// Keep LoggingLevel filled explicitly and sparsely for backwards compatibility and further changes.
	loggingLevelInvalid LoggingLevel = 0
	LoggingLevelTrace   LoggingLevel = 10
	LoggingLevelDebug   LoggingLevel = 20
	LoggingLevelInfo    LoggingLevel = 30
	LoggingLevelWarning LoggingLevel = 40
	LoggingLevelError   LoggingLevel = 50
)
