package blog

import (
	"fmt"
)

// OptionApplier is implemented by implementations controlling their aspection of [Logger] setup.
type OptionApplier interface {
	fmt.Stringer
	apply(l *Logger) error
}

// OptionLogLocations logger will show locations of logging.
func OptionLogLocations() OptionApplier {
	return &optionLogLocations{}
}

// OptionLogFromLevel logger will only log events with level starting from the given l.
func OptionLogFromLevel(l LoggingLevel) OptionApplier {
	return &optionLogFrom{
		l: l,
	}
}

type optionLogLocations struct{}

func (e *optionLogLocations) String() string {
	return "show locations"
}

func (e *optionLogLocations) apply(l *Logger) error {
	l.logLocations = true
	return nil
}

type optionLogFrom struct {
	l LoggingLevel
}

func (e *optionLogFrom) String() string {
	return "log from"
}

func (e *optionLogFrom) apply(l *Logger) error {
	switch e.l {
	case LoggingLevelTrace:
	case LoggingLevelDebug:
	case LoggingLevelInfo:
	case LoggingLevelWarning:
	case LoggingLevelError:
	default:
		return fmt.Errorf("logging-level-uknown[%d]", e.l)
	}

	l.logFrom = e.l
	return nil
}
