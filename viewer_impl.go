package blog

import (
	"go/token"
	"time"

	"github.com/sirkon/blog/internal/core"
)

func NewHumanView() RecordConsumer {
	return &humanRecordView{
		tree: &ctxNodes{},
	}
}

type humanRecordView struct {
	time     time.Time
	level    core.LoggingLevel
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

func (r *humanRecordView) SetLevel(level core.LoggingLevel) {
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
	parent          *recordHumanContextView
	tree            *ctxNodes
	omitFirstFinish bool
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
		parent: r,
		tree:   n,
	}
}

func (r *recordHumanContextView) AppendEmptyGroup(key string) RecordAttributesConsumer {
	n := &ctxNodes{}
	r.tree.payload = append(r.tree.payload, ctxNode{
		key:   key,
		value: n,
	})
	return &recordHumanContextView{
		parent:          r,
		tree:            n,
		omitFirstFinish: true,
	}
}

func (r *recordHumanContextView) AppendError(key string) RecordAttributesConsumer {
	n := &ctxNodes{}
	r.tree.payload = append(r.tree.payload, ctxNode{
		key:   key,
		value: n,
	})
	return &recordHumanContextView{
		parent: r,
		tree:   n,
	}
}

func (r *recordHumanContextView) Finish() RecordAttributesConsumer {
	if r.parent == nil {
		return r
	}

	if r.omitFirstFinish {
		r.omitFirstFinish = false
		return r
	}

	return r.parent
}
