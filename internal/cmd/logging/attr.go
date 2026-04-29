package main

import (
	"log/slog"

	"github.com/sirkon/errors"
)

type attrType struct {
	kind  attrTypeKind
	name  string
	value slog.Value
}

type attrTypeKind int

const (
	attrTypeKindString attrTypeKind = iota
	attrTypeKindInt
	attrTypeKindBool
	attrTypeKindFloat
	attrTypeKindUint16
	attrTypeKindUint32
)

func (k attrTypeKind) String() string {
	switch k {
	case attrTypeKindString:
		return "Str"
	case attrTypeKindInt:
		return "Int"
	case attrTypeKindBool:
		return "Bool"
	case attrTypeKindFloat:
		return "Flt64"
	case attrTypeKindUint16:
		return "Uint16"
	case attrTypeKindUint32:
		return "Uint32"
	default:
		panic(errors.Newf("unsupporter-attr-type-kind(%d)", k))
	}
}
