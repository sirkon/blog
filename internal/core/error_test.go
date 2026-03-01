package core_test

import (
	"fmt"
	"io"

	"github.com/sirkon/blog/internal/core"
)

func ExampleWrapError() {
	var err error

	{
		// Trivial case when every error in the chain is ours.
		err = core.NewError("error")
		err = core.WrapError(err, "check error 1")
		err = core.WrapError(err, "check error 2")
		err = core.WrapError(err, "check error 3")
		fmt.Println("trivial:", err.Error())
	}

	{
		// Pretty trivial case too, when a foreign error is on the tip of the chain
		// and its text can safely be included into the payload.
		err = core.WrapError(io.EOF, "root check")
		err = core.WrapError(err, "check error 1")
		err = core.WrapError(err, "check error 2")
		err = core.WrapError(err, "check error 3")
		fmt.Println("typical:", err.Error())
	}

	{
		// Hardest thing. There are layers of foreign and our errors. We must rely
		// on foreign wrappers text representation in here.
		err = core.WrapError(io.EOF, "root check")
		err = fmt.Errorf("check error 1: %w", err)
		err = core.WrapError(err, "check error 2")
		err = core.JustError(err)
		err = core.WrapError(err, "check error 3")
		fmt.Println("complex:", err.Error())
	}

	err = core.WrapError(io.EOF, "root check")

	// Output:
	// trivial: check error 3: check error 2: check error 1: error
	// typical: check error 3: check error 2: check error 1: root check: EOF
	// complex: check error 3: check error 2: check error 1: root check: EOF
}
