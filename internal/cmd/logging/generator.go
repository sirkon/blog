package main

import (
	"log/slog"
	"math/rand/v2"
	"strconv"
	"time"
	"unsafe"
)

var (
	msgActions = []string{"failed to", "successfully", "started", "finished", "retrying", "timeout during"}
	msgObjects = []string{"database connection", "http request", "user session", "cache lookup", "payload validation", "backend stream"}
	msgReasons = []string{"connection reset by peer", "context canceled", "invalid checksum", "auth token expired", "out of memory"}
	msgFields  = []string{"trace_id", "span_id", "node_id", "retry_count", "latency_ms"}

	keysClassic = []string{"id", "uid", "ip", "msg", "ts", "lv", "pid", "tid", "err", "ctx"}
	keyPrefixes = []string{"http", "db", "auth", "cache", "user", "sys", "internal", "remote"}
	keySubjets  = []string{"request", "connection", "session", "transaction", "payload", "error", "latency", "node"}
	keySuffixes = []string{"id", "ms", "count", "status", "type", "header", "body", "hash", "retry"}

	strTypicalVals = []string{"Hello World!", "/usr/bin/local/service", "ef67-1234-abcd", "found match"}
)

type LogGenerator struct {
	r     *rand.Rand
	data  []byte
	attrs []attrType
}

func NewLogGenerator() *LogGenerator {
	return &LogGenerator{
		r:     rand.New(rand.NewPCG(1, 100_000_000)),
		data:  make([]byte, 0, 16384),
		attrs: make([]attrType, 0, 128),
	}
}

func (g *LogGenerator) Reset() {
	g.data = g.data[:0]
	g.attrs = g.attrs[:0]
}

func (g *LogGenerator) Message() string {
	start := len(g.data)

	switch g.r.IntN(3) {
	case 0: // Типичный ворнинг/ошибка
		g.data = append(g.data, msgActions[g.r.IntN(len(msgActions))]...)
		g.data = append(g.data, ' ')
		g.data = append(g.data, msgObjects[g.r.IntN(len(msgObjects))]...)
		g.data = append(g.data, ':', ' ')
		g.data = append(g.data, msgReasons[g.r.IntN(len(msgReasons))]...)
		ptr := unsafe.Add(unsafe.Pointer(unsafe.SliceData(g.data)), uintptr(start))
		return unsafe.String((*byte)(ptr), len(g.data)-start)

	case 1: // Просто статус
		g.data = append(g.data, msgActions[g.r.IntN(len(msgActions))]...)
		g.data = append(g.data, " processing "...)
		g.data = append(g.data, msgObjects[g.r.IntN(len(msgObjects))]...)
		ptr := unsafe.Add(unsafe.Pointer(unsafe.SliceData(g.data)), uintptr(start))
		return unsafe.String((*byte)(ptr), len(g.data)-start)

	default: // Каша из полей
		g.data = append(g.data, "processed "...)
		g.data = append(g.data, msgObjects[g.r.IntN(len(msgObjects))]...)
		g.data = append(g.data, " with "...)
		g.data = append(g.data, msgFields[g.r.IntN(len(msgFields))]...)
		g.data = append(g.data, '=')
		g.data = strconv.AppendInt(g.data, int64(g.r.IntN(1000)), 10)
		ptr := unsafe.Add(unsafe.Pointer(unsafe.SliceData(g.data)), uintptr(start))
		return unsafe.String((*byte)(ptr), len(g.data)-start)
	}
}

func (g *LogGenerator) Attrs() []attrType {
	g.generateAttrs()
	return g.attrs
}

func (g *LogGenerator) realisticInt() int {
	p := g.r.IntN(100)
	switch {
	case p < 35:
		return g.r.IntN(10) // 1 знак (0-9)
	case p < 55:
		return g.r.IntN(90) + 10 // 2 знака (10-99)
	case p < 70:
		return g.r.IntN(900) + 100 // 3 знака (100-999)
	case p < 78:
		return g.r.IntN(9000) + 1000 // 4 знака
	case p < 83:
		return g.r.IntN(90000) + 10000 // 5 знаков
	case p < 87:
		return g.r.IntN(900000) + 100000 // 6 знаков
	case p < 89:
		return g.r.IntN(9000000) + 1000000 // 7 знаков
	case p < 90:
		return g.r.IntN(90000000) + 10000000 // 8 знаков
	default:
		return int(time.Now().UnixNano()) // 19 знаков (Таймстамп)
	}
}

func (g *LogGenerator) randomAttr() {
	p := g.r.IntN(100)
	key := g.generateRandomKey()

	switch {
	case p < 45: // String (45%)
		g.attrs = append(g.attrs, attrType{
			kind:  attrTypeKindString,
			name:  key,
			value: slog.StringValue(strTypicalVals[g.r.IntN(len(strTypicalVals))]),
		})

	case p < 80: // Int64 (35%)
		g.attrs = append(g.attrs, attrType{
			kind:  attrTypeKindInt,
			name:  key,
			value: slog.IntValue(g.realisticInt()),
		})

	case p < 90: // Bool (10%)
		g.attrs = append(g.attrs, attrType{
			kind:  attrTypeKindBool,
			name:  key,
			value: slog.BoolValue(g.r.IntN(2) == 1),
		})

	case p < 95: // Float64 (5%)
		g.attrs = append(g.attrs, attrType{
			kind:  attrTypeKindFloat,
			name:  key,
			value: slog.Float64Value(g.r.Float64() * 100),
		})

	default: // Uint16/32 (5%)
		if g.r.IntN(2) == 0 {
			g.attrs = append(g.attrs, attrType{
				kind:  attrTypeKindUint16,
				name:  key,
				value: slog.Uint64Value(uint64(uint16(g.r.Uint32()))),
			})
			return
		}

		g.attrs = append(g.attrs, attrType{
			kind:  attrTypeKindUint32,
			name:  key,
			value: slog.Uint64Value(uint64(g.r.Uint32())),
		})
	}
}

func (g *LogGenerator) generateAttrs() {
	p := g.r.IntN(100)

	var l int
	switch {
	case p < 40:
		l = g.r.IntN(4)
	case p < 85:
		l = g.r.IntN(5) + 4
	case p < 95:
		l = g.r.IntN(16) + 10
	default:
		l = g.r.IntN(10) + 25
	}

	for range l {
		g.randomAttr()
	}
}

func (g *LogGenerator) generateRandomKey() string {
	// 1. С вероятностью 30% выдаем "короткую классику"
	if g.r.IntN(10) < 3 {
		return keysClassic[g.r.IntN(len(keysClassic))]
	}

	sep := byte('_')
	if g.r.IntN(4) == 0 {
		sep = '-'
	}
	if g.r.IntN(10) == 0 {
		sep = '.'
	}

	// 2. С вероятностью 70% собираем "монстра"
	parts := g.r.IntN(3) + 1 // 1, 2 или 3 части
	start := len(g.data)

	g.data = append(g.data, keyPrefixes[g.r.IntN(len(keyPrefixes))]...)
	if parts > 1 {
		g.data = append(g.data, sep)
		g.data = append(g.data, keySubjets[g.r.IntN(len(keySubjets))]...)
	}

	if parts > 2 {
		g.data = append(g.data, sep)
		g.data = append(g.data, keySuffixes[g.r.IntN(len(keySuffixes))]...)
	}

	ptr := unsafe.Add(unsafe.Pointer(unsafe.SliceData(g.data)), uintptr(start))
	return unsafe.String((*byte)(ptr), len(g.data)-start)
}
