package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"os"

	"github.com/sirkon/blog"
)

func main() {
	incoming := os.Stdin
	var buf []byte
	var tmp [4096]byte

	dst := blog.NewPrettyWriter(os.Stdout).WithDarkTerminal()
	var lastLoop bool

mainloop:
	for !lastLoop {
		n, err := incoming.Read(tmp[:])
		if err != nil {
			if err != io.EOF {
				fmt.Println(fmt.Errorf("read from stdin: %w", err))
				os.Exit(1)
			}

			lastLoop = true
		}
		buf = append(buf, tmp[:n]...)

		var i int
		for {
			if len(buf)-i < 6 {
				buf = realign(i, buf)
				continue mainloop
			}

			pos := i + 6
			length, off := binary.Uvarint(buf[pos:])
			if off <= 0 {
				if off == 0 {
					buf = realign(i, buf)
					continue mainloop
				}

				fmt.Println("malformed record length")
				os.Exit(1)
			}

			pos += off
			if len(buf)-pos < int(length) {
				buf = realign(i, buf)
				continue mainloop
			}

			if _, err := dst.Write(buf[i : pos+int(length)]); err != nil {
				fmt.Println(fmt.Errorf("write into pretty writer: %w", err))
			}

			i = pos + int(length)
		}
	}

	if len(buf) > 0 {
		fmt.Println(len(buf), "unprocessed bytes left")
		os.Exit(1)
	}
}

func realign(off int, buf []byte) []byte {
	if off == 0 {
		return buf
	}

	length := len(buf) - off
	copy(buf, buf[off:])
	return buf[:length]
}
