package blog

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/binary"
	"fmt"
	"hash/crc32"
	"io"
	"math/bits"
	"os"
	"runtime"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	"github.com/sirkon/blog/internal/attribute"
)

const (
	defaultRecordWidth = 1024

	// We tries not to keep too much.
	wishRecordIsNoLongerThan = 64 * 1024
	recordBufferMaxCapacity  = 65536
)

// Logger records and serialize information about each call to its
// Log, Debug, Info, Warn, and Error methods.
type Logger struct {
	w          WriteSyncer
	bufs       *sync.Pool
	inProgress uint64

	logFrom       LoggingLevel
	prefixPayload []byte
	logLocations  bool
}

// NewLogger creates a new logger writing into the given WriteSyncer.
func NewLogger(w WriteSyncer, options ...OptionApplier) (*Logger, error) {
	res := &Logger{
		w:    w,
		bufs: &sync.Pool{},
	}
	for _, option := range options {
		if err := option.apply(res); err != nil {
			return nil, fmt.Errorf("apply option %s: %w", option, err)
		}
	}

	return res, nil
}

// WriteSyncer is just a writer whose implementation must be aware of concurrent logging output.
type WriteSyncer interface {
	io.Writer
}

// Trace logs at [LoggingLevelTrace].
func (l *Logger) Trace(ctx context.Context, msg string, attrs ...attribute.Attr) {
	l.logLevel(ctx, LoggingLevelTrace, msg, 0, attrs...)
}

// Debug logs at [LoggingLevelDebug].
func (l *Logger) Debug(ctx context.Context, msg string, attrs ...attribute.Attr) {
	l.logLevel(ctx, LoggingLevelDebug, msg, 0, attrs...)
}

// Info logs at [LoggingLevelInfo].
func (l *Logger) Info(ctx context.Context, msg string, attrs ...attribute.Attr) {
	l.logLevel(ctx, LoggingLevelInfo, msg, 0, attrs...)
}

// Warn logs at [LoggingLevelWarning].
func (l *Logger) Warn(ctx context.Context, msg string, attrs ...attribute.Attr) {
	l.logLevel(ctx, LoggingLevelWarning, msg, 0, attrs...)
}

// Error logs at [LoggingLevelError].
func (l *Logger) Error(ctx context.Context, msg string, attrs ...attribute.Attr) {
	l.logLevel(ctx, LoggingLevelInfo, msg, 0, attrs...)
}

// With returns a Logger that includes the given attributes
// in each output operation.
func (l *Logger) With(ctx ...attribute.Attr) *Logger {
	c := *l
	// TODO serialize ctx into the c.prefixPayload
	return &c
}

// LogPanic logs given stack trace at the Panic logging level.
// Is to be used withing panic recovery routines, something like:
//
//		defer func() {
//		    r := recover()
//	     if r == nil {
//	         return
//	     }
//	     info := blog.LogPanicInfo(r)
//	     blog.LogPanic(ctx, logger, debug.StackTrace(), info)
//		}
//
// Panic text payload will be stored in gzipped form as a message.
func LogPanic(ctx context.Context, log *Logger, stacktrace []byte, info attribute.Attr) {
	var gzipped bytes.Buffer
	if err := compressStacktrace(&gzipped, stacktrace); err != nil {
		// We may only fail due to lack of memory. Our last hope is to write the stacktrace
		// into the stderr.
		_, _ = os.Stderr.Write(stacktrace)
		return
	}

	log.logLevel(
		ctx,
		loggingLevelPanic,
		unsafe.String(unsafe.SliceData(gzipped.Bytes()), gzipped.Len()),
		0,
		info,
	)
}

// LogPanicInfo extract panic "recovered" attribute as meaningful form as possible.
// Should be used within recovery procedures, see at [LogPanic] for usage example.
func LogPanicInfo(v any) attribute.Attr {
	var attr attribute.Attr
	key := "recovered"
	switch v := v.(type) {
	case error:
		attr = attribute.Error(key, v)
	case bool:
		attr = attribute.Bool(key, v)
	case int:
		attr = attribute.Int(key, v)
	case int8:
		attr = attribute.Int8(key, v)
	case int16:
		attr = attribute.Int16(key, v)
	case int32:
		attr = attribute.Int32(key, v)
	case int64:
		attr = attribute.Int64(key, v)
	case uint:
		attr = attribute.Uint(key, v)
	case uint8:
		attr = attribute.Uint8(key, v)
	case uint16:
		attr = attribute.Uint16(key, v)
	case uint32:
		attr = attribute.Uint32(key, v)
	case uint64:
		attr = attribute.Uint64(key, v)
	case float32:
		attr = attribute.Flt32(key, v)
	case float64:
		attr = attribute.Flt64(key, v)
	case string:
		attr = attribute.Str(key, v)
	case fmt.Stringer:
		attr = attribute.Stg(key, v)
	case []byte:
		attr = attribute.Bytes(key, v)
	case attribute.Serializer:
		attr = attribute.Obj(key, v)
	case []bool:
		attr = attribute.Bools(key, v)
	case []int:
		attr = attribute.Ints(key, v)
	case []int8:
		attr = attribute.Int8s(key, v)
	case []int16:
		attr = attribute.Int16s(key, v)
	case []int32:
		attr = attribute.Int32s(key, v)
	case []int64:
		attr = attribute.Int64s(key, v)
	case []uint:
		attr = attribute.Uints(key, v)
	case []uint16:
		attr = attribute.Uint16s(key, v)
	case []uint32:
		attr = attribute.Uint32s(key, v)
	case []uint64:
		attr = attribute.Uint64s(key, v)
	case []float32:
		attr = attribute.Flt32s(key, v)
	case []float64:
		attr = attribute.Flt64s(key, v)
	case []string:
		attr = attribute.Strs(key, v)
	default:
		attr = attribute.Str(key, fmt.Sprintf("%#v", v))
	}
	return attr
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
//   - Some custom payload provide by [Logger.appendCustom] method.
//   - Message UVARING(message) message
//   - Payload built with [Logger.With] (prefixPayload).
//   - Serialized(attrs)
//
// [Logger.With] payload looks the same as its attributes would be in the head of attrs explicitly.
// So it is just concat.
//
// Beware that events may not be monotone in order: there's a possibility another goroutine starts 10s
// after yet manages to pass through serialization earlier.
func (l *Logger) logLevel(
	ctx context.Context,
	level LoggingLevel,
	msg string,
	locationSkip int,
	attrs ...attribute.Attr,
) {
	if level < l.logFrom {
		return
	}

	atomic.AddUint64(&l.inProgress, 1)
	defer func() {
		atomic.AddUint64(&l.inProgress, ^uint64(0))
	}()

	var logDataPtr *[]byte
	val := l.bufs.Get()
	if val == nil {
		tmp := make([]byte, 0, defaultRecordWidth)
		logDataPtr = &tmp
	} else {
		logDataPtr = val.(*[]byte)
	}

	// Omit the first 1 + 4 + 10 bytes as we store 0xff + CRC32 + uvarint(record_size) in here.
	// This uvarint part's length may differ, and we may need an adjustment to pack that header tightly.
	logData := *logDataPtr
	var record []byte
	record = logData[15:15]
	defer l.putBufferBack(logDataPtr)

	// Now, put fields.

	// Time.
	record = binary.LittleEndian.AppendUint64(record, uint64(time.Now().UnixNano()))

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

	// Custom static fields. They are meant to be
	record = l.appendCustom(ctx, record)

	// Message
	record = binary.AppendUvarint(record, uint64(len(msg)))
	record = append(record, msg...)

	// With payload.
	record = append(record, l.prefixPayload...)

	// Serialize our attrs.
	for _, attr := range attrs {
		record = attribute.AppendSerialized(record, attr)
	}

	// Get CRC32, adjust the placement, put header and form a data to write.
	checksum := crc32.Checksum(record, crcTable)
	width := 5 + (bits.Len64(uint64(len(record)))+6)/7 // 0xFF + CRC + UVARINT(record.length)
	data := logData[15-width:]
	data = append(data, 0xff)
	data = binary.LittleEndian.AppendUint32(data, checksum)
	data = binary.AppendUvarint(data, uint64(len(record)))
	data = data[:width+len(record)]
	*logDataPtr = data

	// Write collected data.
	if _, err := l.w.Write(data); err != nil {
		fmt.Println("failed to write logged data:", err)
	}
}

func (l *Logger) putBufferBack(buf *[]byte) {
	if len(*buf) > wishRecordIsNoLongerThan {
		// The buffer grew too large, we better not to keep it.
		return
	}
	if atomic.LoadUint64(&l.inProgress) > recordBufferMaxCapacity {
		// Having recordBufferMaxCapacity pool is enough,
		return
	}
	*buf = (*buf)[:0]
	l.bufs.Put(buf)
}

// LoggingLevel represents logging levels.
type LoggingLevel uint8

const (
	// Keep LoggingLevel filled explicitly and sparsely for backwards compatibility and further changes.
	loggingLevelInvalid LoggingLevel = 0
	// LoggingLevelTrace represents Trace logging level.
	LoggingLevelTrace LoggingLevel = 10
	// LoggingLevelDebug represents Debug logging level.
	LoggingLevelDebug LoggingLevel = 20
	// LoggingLevelInfo represents Info logging level.
	LoggingLevelInfo LoggingLevel = 30
	// LoggingLevelWarning represents Warn logging level.
	LoggingLevelWarning LoggingLevel = 40
	// LoggingLevelError represents Error logging level.
	LoggingLevelError LoggingLevel = 50
	loggingLevelPanic LoggingLevel = 60
)

func (l LoggingLevel) String() string {
	switch l {
	case LoggingLevelTrace:
		return "TRACE"
	case LoggingLevelDebug:
		return "DEBUG"
	case LoggingLevelInfo:
		return "INFO"
	case LoggingLevelWarning:
		return "WARN"
	case LoggingLevelError:
		return "ERROR"
	case loggingLevelPanic:
		return "PANIC"
	default:
		return fmt.Sprintf("logging-level-unknown[%d]", uint8(l))
	}
}

// compressStacktrace do not apply "proper" error processing. An error itself may only
// be a consequence of [bytes.Buffer] errors and these may only happen due to a RAM shortage.
// We don't have a luxury to append a right context in these conditions.
func compressStacktrace(dst *bytes.Buffer, stacktrace []byte) (err error) {
	w := gzip.NewWriter(dst)
	defer func() {
		if err != nil {
			_ = w.Close()
			return
		}
		err = w.Close()
	}()
	defer func() {
		if err != nil {
			_ = w.Flush()
			return
		}
		err = w.Flush()
	}()
	if _, err := w.Write(stacktrace); err != nil {
		return err
	}

	return nil
}
