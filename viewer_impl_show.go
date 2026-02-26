package blog

import (
	"fmt"
	"strings"
)

func (r *humanRecordView) String() string {
	var builder strings.Builder

	builder.WriteString(r.time.Format("2006-01-02T15:04:05"))
	builder.WriteByte(' ')
	builder.WriteString(r.level.String())
	builder.WriteByte(' ')
	if r.location.IsValid() {
		builder.WriteByte('(')
		builder.WriteString(r.location.String())
		builder.WriteString(") ")
	}
	builder.WriteString(r.message)
	builder.WriteByte('\n')

	showTree(&builder, r.tree, "  ")

	return builder.String()
}

func showTree(builder *strings.Builder, nodes *ctxNodes, prefix string) {
	for i, node := range nodes.payload {
		last := i == len(nodes.payload)-1

		// prefix already includes indentation and vertical bars from parents
		builder.WriteString(prefix)
		if last {
			builder.WriteString("└─ ")
		} else {
			builder.WriteString("├─ ")
		}

		builder.WriteString(node.key)

		v, ok := node.value.(*ctxNodes)
		if !ok {
			builder.WriteString(": ")
			builder.WriteString(fmt.Sprint(node.value))
			builder.WriteByte('\n')
			continue
		}

		builder.WriteByte('\n')

		// For children: if current node is last -> no vertical bar; else keep it.
		childPrefix := prefix
		if last {
			childPrefix += "   " // aligns with "└─ "
		} else {
			childPrefix += "│  " // keeps vertical line for siblings below
		}

		showTree(builder, v, childPrefix)
	}
}
