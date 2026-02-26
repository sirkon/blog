package blog

import (
	"go/token"
	"time"
)

func NewHumanView() RecordConsumer {
	return &humanRecordView{
		tree: &ctxNodes{},
	}
}

type humanRecordView struct {
	time     time.Time
	level    LoggingLevel
	location token.Position
	message  string

	tree *ctxNodes
}

type ctxNodes struct {
	payload []ctxNode
}

type ctxNode struct {
	key   string
	value any
}

func (r *humanRecordView) Reset() {
	r.location = token.Position{}
	r.tree = &ctxNodes{
		payload: r.tree.payload[:0],
	}
}

func (r *humanRecordView) SetTime(timeUnixNano uint64) {
	r.time = time.Unix(0, int64(timeUnixNano))
}

func (r *humanRecordView) SetLevel(level LoggingLevel) {
	r.level = level
}

func (r *humanRecordView) SetLocation(file string, line int) {
	r.location = token.Position{
		Filename: file,
		Line:     line,
	}
}

func (r *humanRecordView) SetMessage(text string) {
	r.message = text
}

func (r *humanRecordView) RootAttrConsumer() RecordAttributesConsumer {
	return &recordHumanContextView{
		tree: r.tree,
	}
}

type recordHumanContextView struct {
	tree *ctxNodes
}

func (r *recordHumanContextView) Append(key string, value any) {
	r.tree.payload = append(r.tree.payload, ctxNode{
		key:   key,
		value: value,
	})
}

func (r *recordHumanContextView) AppendGroup(key string) RecordAttributesConsumer {
	n := &ctxNodes{}
	r.tree.payload = append(r.tree.payload, ctxNode{
		key:   key,
		value: n,
	})
	return &recordHumanContextView{
		tree: n,
	}
}

func (r *recordHumanContextView) AppendError(key string) RecordAttributesConsumer {
	n := &ctxNodes{}
	r.tree.payload = append(r.tree.payload, ctxNode{
		key:   key,
		value: n,
	})
	return &recordHumanContextView{
		tree: n,
	}
}
