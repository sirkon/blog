package beer

import (
	"errors"
)

// Is mirrors [errors.Is].
func Is(err error, target error) bool {
	return errors.Is(err, target)
}

// AsType mirrors [errors.AsType].
func AsType[E error](err error) (E, bool) {
	return errors.AsType[E](err)
}
