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
