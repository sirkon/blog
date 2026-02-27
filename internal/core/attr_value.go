package core

// Value uses that black magic borrowed from [slog.Value].
//
// Quote:
//
//	 // A Value can represent any Go value, but unlike type any,
//	 // it can represent most small values without an allocation.
//	 // The zero Value corresponds to nil.
//	 type Value struct {
//		    _ [0]func() // disallow ==
//		    // num holds the value for Kinds Int64, Uint64, Flt64, Bool and Duration,
//		    // the string length for KindString, and nanoseconds since the epoch for KindTime.
//		    num uint64
//		    // If any is of type Kind, then the value is in num as described above.
//		    // If any is of type *time.Location, then the Kind is Time and time.Time value
//		    // can be constructed from the Unix nanos in num and the location (monotonic time
//		    // is not preserved).
//		    // If any is of type stringptr, then the Kind is Str and the string value
//		    // consists of the length in num and the pointer in any.
//		    // Otherwise, the Kind is Any and any is the value.
//		    // (This implies that Attrs cannot store values of type Kind, *time.Location
//		    // or stringptr.)
//		    any any
//	 }
//
// But unlike the slog.Value we only allow restrictive [Serializer] instead of any to
// keep it in line for our purposes and to avoid dynamic dispatch with
//
//	x.Value.Any().(blog.Serializer)
type Value struct {
	_   [0]func() // disallow ==
	num uint64
	srl Serializer
}

// Serializer blog only supports predefined values and values of this type.
type Serializer interface {
	Serialize(src []byte) []byte
}

type (
	stringPtr struct {
		whateverPtr
		byte
	}
	bytesPtr struct {
		whateverPtr
		byte
	}
	attrsPtr struct {
		whateverPtr
		Attr
	}
	errorPtr struct {
		whateverPtr
		// TODO Add beer.Error
	}
	boolSlicePtr struct {
		whateverPtr
		bool
	}
	intSlicePtr struct {
		whateverPtr
		int
	}
	int8SlicePtr struct {
		whateverPtr
		int8
	}
	int16SlicePtr struct {
		whateverPtr
		int16
	}
	int32SlicePtr struct {
		whateverPtr
		int32
	}
	int64SlicePtr struct {
		whateverPtr
		int64
	}
	uintSlicePtr struct {
		whateverPtr
		uint
	}
	uint8SlicePtr struct {
		whateverPtr
		uint8
	}
	uint16SlicePtr struct {
		whateverPtr
		uint16
	}
	uint32SlicePtr struct {
		whateverPtr
		uint32
	}
	uint64SlicePtr struct {
		whateverPtr
		uint64
	}
	float32SlicePtr struct {
		whateverPtr
		float32
	}
	float64SlicePtr struct {
		whateverPtr
		float64
	}
	stringSlicePtr struct {
		whateverPtr
		string
	}
	groupPtr struct {
		whateverPtr
		Attr
	}
)

type whateverPtr struct{}

// Serialize dummy method to cheat compiler.
func (p *whateverPtr) Serialize(src []byte) []byte { return src }

var (
	_ Serializer = new(whateverPtr)
)
