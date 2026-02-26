package blog

import (
	"encoding/binary"
)

// RecordConsumer API to consume record data.
type RecordConsumer interface {
	Finish() error

	SetTime(timeUnixNano uint64)
	SetLevel(level LoggingLevel)
	SetLocation(file string, line int)
	SetMessage(text string)

	RecordAttributesConsumer
}

// RecordAttributesConsumer API to consume record attributes.
type RecordAttributesConsumer interface {
	Append(key string, value any)
	AppendGroup(key string) RecordAttributesConsumer
	AppendError(key string) RecordAttributesConsumer
}

// RecordSafeView provides human-readable output over [Logger] produced binary stream.
// The input data considered to be safe, so no 0xFF, CRC32 and length will be made.
//
// It is aimed at
func RecordSafeView(cons RecordConsumer, data []byte) error {
	// Pass 0xFF, CRC32 and record length.
	data = data[5:]
	_, varintLength := binary.Uvarint(data)
	data = data[varintLength:]

	// So, we have a record content in our hands.
	return nil
}
