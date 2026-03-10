package core_test

import (
	"fmt"
	"io"
	"testing"

	"github.com/sirkon/blog/beer"
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

func TestRegression(t *testing.T) {
	var err error
	err = core.WrapError(io.EOF, "wrap 1").Str("tag", "tag1")
	err = core.JustError(err).Int("key", 12)
	err = core.WrapError(err, "wrap 2").Bool("bool", true)
	err = fmt.Errorf("foreign wrap 1: %w", err)
	err = beer.Wrap(err, "wrap 3").Str("tag", `"quoted tag value"`)
	err = fmt.Errorf("foreign wrap 2: %w", err)

	expected := "foreign wrap 2: wrap 3: foreign wrap 1: wrap 2: wrap 1: EOF"
	if err.Error() != expected {
		t.Errorf("wrong error message: expected %q, got %q", expected, err.Error())
	}
}
