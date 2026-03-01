package core

func ErrorNodeNew(msg string) Attr {
	return Attr{
		Key:  msg,
		kind: ValueKindNewNode,
	}
}

func ErrorNodeWrap(msg string) Attr {
	return Attr{
		Key:  msg,
		kind: ValueKindWrapNode,
	}
}

func ErrorNodeWrapInherited(msg string) Attr {
	return Attr{
		Key:  msg,
		kind: ValueKindWrapInheritedNode,
	}
}

func ErrorNodeJustContext() Attr {
	return Attr{
		Key:  "",
		kind: ValueKindJustContextNode,
	}
}

func ErrorNodeJustContextInherited() Attr {
	return Attr{
		Key:  "",
		kind: ValueKindJustContextInheritedNode,
	}
}

func ErrorNodeForeignErrorText(txt string) Attr {
	return Attr{
		Key:  txt,
		kind: ValueKindForeignErrorText,
	}
}

func ErrorNodeForeignErrorFormat(txt string) Attr {
	return Attr{
		Key:  txt,
		kind: ValueKindForeignErrorFormat,
	}
}

func ErrorNodePhantomContext() Attr {
	return Attr{
		kind: ValueKindPhantomContextNode,
	}
}

func ErrorNodeLocation(file string, line int) Attr {
	return Attr{
		Key: file,
		Value: Value{
			num: uint64(line),
		},
		kind: ValueKindLocationNode,
	}
}
