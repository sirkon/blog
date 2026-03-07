package beer

import (
	"github.com/sirkon/blog/internal/core"
)

// Error implements error interface and provides structured context for [blog.Logger].
type Error = core.Error

// New creates new *[Error] value with given message that implements [error] interface and
// supports structural context.
func New(msg string) *Error {
	return core.NewError(msg)
}

// Newf same as [New], just with format instead of a fixed message.
func Newf(format string, a ...any) *Error {
	return core.NewErrorf(format, a...)
}

// Wrap wraps an [error] with given message with the support of additional structural context.
func Wrap(err error, msg string) *Error {
	return core.WrapError(err, msg)
}

// Wrapf same as [Wrap], just with a format instead of fixed message.
func Wrapf(err error, format string, a ...any) *Error {
	return core.WrapErrorf(err, format, a...)
}

// Just wraps given [error] without a message, just allow to add a context.
func Just(err error) *Error {
	return core.JustError(err)
}

// Spec adds a typed *specialization* into the err. This is meant to be used for domain
// specific errors. Custom types are less than desired with blog/beer since they lack
// context handling and propagation support [beer.Error] has.
func Spec(err error, spec any) *Error {
	return core.Spec(err, spec)
}

// AsSpec returned previously stored spec from the error.
func AsSpec[T any](err error) (T, bool) {
	return core.AsSpec[T](err)
}

// IsSpec checks if the given spec was added into err.
func IsSpec[T any](err error) bool {
	return core.IsSpec[T](err)
}
