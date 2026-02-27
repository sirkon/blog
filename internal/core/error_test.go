package core_test

import (
	"fmt"

	"github.com/sirkon/blog/internal/core"
)

func ExampleWrapError() {
	var err error
	err = core.NewError("error")
	err = fmt.Errorf("check error 1: %w", err)
	err = core.WrapError(err, "check error 2")
	err = core.JustError(err)
	err = core.WrapError(err, "check error 3")

	fmt.Println(err.Error())
	// Output:
	//  check error 3: check error 2: check error 1: error
}
