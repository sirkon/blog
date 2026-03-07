package core_test

import (
	"fmt"
	"io"

	"github.com/sirkon/blog/internal/core"
)

func ExampleSpec() {
	{
		// Spec on foreign pin
		err := fmt.Errorf("wrap: %w", io.EOF)
		err = core.Spec(err, new(1))
		fmt.Println("spec on foreign error |", err, "|", asSpec(err), core.IsSpec[*int](err))
	}

	{
		// Spec on top of the *Error
		var err error
		err = core.WrapError(io.EOF, "wrap")
		err = core.Spec(err, new(2))
		fmt.Println("spec on *Error |", err, "|", asSpec(err), core.IsSpec[*int](err))
	}

	{
		// Spec on top of the foreign error having *Error beneath
		var err error
		err = core.NewError("error")
		err = fmt.Errorf("wrap: %w", err)
		err = core.Spec(err, new(3))
		fmt.Println("spec on foreign error having *Error beneath |", err, "|", asSpec(err), core.IsSpec[*int](err))
	}

	{
		// Spec is beneath layers of foreign wraps having *Error in them.
		var err error
		err = core.WrapError(io.EOF, "wrap")
		err = core.Spec(err, new(4))
		err = fmt.Errorf("wrap: %w", err)
		err = core.WrapError(err, "wrap")
		err = fmt.Errorf("wrap: %w", err)
		fmt.Println("spec beneath layers of *Error and foreign wraps |", err, "|", asSpec(err), core.IsSpec[*int](err))
	}

	{
		// Without a spec
		var err error
		err = fmt.Errorf("wrap: %w", io.EOF)
		fmt.Println("error without a spec |", err, "|", asSpec(err), core.IsSpec[*int](err))
	}

	// Output:
	// spec on foreign error | wrap: EOF | 1 true
	// spec on *Error | wrap: EOF | 2 true
	// spec on foreign error having *Error beneath | wrap: error | 3 true
	// spec beneath layers of *Error and foreign wraps | wrap: wrap: wrap: wrap: EOF | 4 true
	// error without a spec | wrap: EOF | -1 false
}

func asSpec(err error) int {
	v, ok := core.AsSpec[*int](err)
	if !ok {
		return -1
	}

	return *v
}
