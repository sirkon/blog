package beer_test

import (
	stdbeer "errors"
	"fmt"
	"io"
	"os"
	"testing"

	"github.com/sirkon/blog/internal/core"
)

var count int

func BenchmarkBeerWrapFixed(b *testing.B) {
	b.ReportAllocs()

	for range b.N {
		err := getBeerWrapErrorNoContext()
		count += len(err.Error())
	}
}

func BenchmarkBeerWrapFixedNoError(b *testing.B) {
	b.ReportAllocs()

	for range b.N {
		_ = getBeerWrapErrorNoContext()
	}
}

func BenchmarkFmtErrorfFixed(b *testing.B) {
	b.ReportAllocs()

	for range b.N {
		err := getFmtErrorfFixed()
		count += len(err.Error())
	}
}

func BenchmarkBeerWrapf(b *testing.B) {
	b.ReportAllocs()

	for range b.N {
		err := getBeerWrapf()
		count += len(err.Error())
	}
}

func BenchmarkBeerWrapContext(b *testing.B) {
	b.ReportAllocs()

	for range b.N {
		err := getBeerWrapContext()
		count += len(err.Error())
	}
}

func BenchmarkFmtErrorfShortContext(b *testing.B) {
	b.ReportAllocs()

	for range b.N {
		err := getFmtErrorfShortContext()
		count += len(err.Error())
	}
}

func BenchmarkBeerWrapLongContext(b *testing.B) {
	b.ReportAllocs()

	for range b.N {
		err := getBeerWrapLargerContext()
		count += len(err.Error())
	}
}

func BenchmarkFmtErrorfLongContext(b *testing.B) {
	b.ReportAllocs()

	for range b.N {
		err := getFmtErrorfLargerContext()
		count += len(err.Error())
	}
}

func getBeerWrapErrorNoContext() error {
	var err error = core.NewError("some error")
	err = core.WrapError(err, "wrap 1")
	err = core.WrapError(err, "wrap 2")
	err = core.WrapError(err, "wrap 3")
	err = core.WrapError(err, "wrap 4")

	return err
}

func getFmtErrorfFixed() error {
	err := stdbeer.New("some error")
	err = fmt.Errorf("wrap 1: %w", err)
	err = fmt.Errorf("wrap 2: %w", err)
	err = fmt.Errorf("wrap 3: %w", err)
	err = fmt.Errorf("wrap 4: %w", err)

	return err
}

func getBeerWrapf() error {
	err := os.ErrNotExist
	filename := "query.sql"
	dbname := "db-1"
	domain := "sales"
	deparmentID := "deparment-123"

	err = core.WrapErrorf(err, "open query file %s", filename)
	err = core.WrapErrorf(err, "query users in DB %s", dbname)
	err = core.WrapErrorf(err, "get domain %s users", domain)
	err = core.WrapErrorf(err, "create iterator over deparment %s users", deparmentID)

	return err
}

func getFmtErrorfShortContext() error {
	err := os.ErrNotExist
	filename := "query.sql"
	dbname := "db-1"
	domain := "sales"
	deparmentID := "deparment-123"

	err = fmt.Errorf("open query file %s: %w", filename, err)
	err = fmt.Errorf("query users in DB %s: %w", dbname, err)
	err = fmt.Errorf("get domain %s users: %w", domain, err)
	err = fmt.Errorf("create iterator over deparment %s users: %w", deparmentID, err)

	return err
}

func getBeerWrapContext() error {
	err := core.NewError("some error").Int("some-int", 12).Str("some-str", "hello")
	err = core.WrapError(err, "wrap 1").Str("wrap-str", "world")
	err = core.WrapError(err, "wrap 2")
	err = core.WrapError(err, "wrap 3").Str("method", "Method")

	return err
}

func getBeerWrapLargerContext() error {
	err := core.WrapError(io.ErrClosedPipe, "read stream").Int("buf-length", 4096)
	err = core.WrapError(err, "read with retries").
		Flt64("average-failure-response-delay", 0.12).
		Int("how-many-retries", 4)
	err = core.WrapErrorf(err, "read GetFile stream")
	err = core.WrapError(err, "transfer data").
		Int("transfered-before-failure", 16384).
		Int("retries-made", 9)
	err = core.WrapError(err, "get image data").Str("data-id", "6142a749-aaa2-4383-b6bd-9d0adfd9d330")
	err = core.WrapError(err, "resize image").
		Str("img-type", "image/png").
		Flt64("scale", 1.2).
		Str("sharpening-type", "GAUSSIAN")
	err = core.WrapError(err, "process user avatar")
	err = core.WrapErrorf(err, "finish %s", "user-create-routine").
		Str("user-id", "e0e3804f-b0f7-4fc6-a995-fd20c4994810")
	err = core.WrapError(err, "replay wal session").
		Str("wal-session-id", "0bf25c6a-d5d6-4b08-b381-9c6a26ea55c0").
		Int("session-replay-no", 3).
		Flt64("replay-duration", 0.87323).
		Int("replays-left", 7)

	return err
}

func getFmtErrorfLargerContext() error {
	err := fmt.Errorf("read %d bytes of stream: %w", 4096, io.ErrClosedPipe)
	err = fmt.Errorf("read with retries average-delay[%f] retries-done[%d]: %w", 0.12, 4, err)
	err = fmt.Errorf("read GetFile stream: %w", err)
	err = fmt.Errorf("transfer data bytes-completed[%d] total-retries[%d]: %w", 16384, 9, err)
	err = fmt.Errorf("get image data from record %q: %w", "6142a749-aaa2-4383-b6bd-9d0adfd9d330", err)
	err = fmt.Errorf("resize %s image with the scale %f: %w", "image/jpeg", 1.2, err)
	err = fmt.Errorf("process user avatar: %w", err)
	err = fmt.Errorf(
		"finish process[%s] user-id[%s]: %w",
		"user-create-routine",
		"e0e3804f-b0f7-4fc6-a995-fd20c4994810",
		err,
	)
	err = fmt.Errorf(
		"replay wal session=%q session-replay-no=%d replay-duration=%f replays-left=%d: %w",
		"0bf25c6a-d5d6-4b08-b381-9c6a26ea55c0",
		3,
		0.87323,
		7,
		err,
	)

	return err
}

func init() {
	core.InsertLocationsOff()
}
