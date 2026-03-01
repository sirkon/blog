package beer

import (
	"github.com/sirkon/blog/internal/core"
)

// InsertLocationsOn [New], [Newf], [Wrap], [Wrapf] and [Just]
// will insert locations of their calls.
//
// Meant to be used in for debugging purposes only, is off by default.
func InsertLocationsOn() {
	core.InsertLocationsOn()
}

// InsertLocationsOff disables locations capturing.
func InsertLocationsOff() {
	core.InsertLocationsOff()
}
