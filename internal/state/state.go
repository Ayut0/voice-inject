package state

type State int

// iota is used to assign sequential integer values to the constants
// auto-incrementing integers starting at 0
const (
	Idle         State = iota //0
	Recording                 //1
	Transcribing              //2
	Injecting                 //3
)

func (s State) String() string {
	switch s {
	case Idle:
		return "idle"
	case Recording:
		return "recording"
	case Transcribing:
		return "transcribing"
	case Injecting:
		return "injecting"
	default:
		return "unknown state"
	}
}
