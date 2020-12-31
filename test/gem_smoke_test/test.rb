require "thread_weaver"

ThreadWeaver::IterativeRaceDetector.new(
  setup: -> {},
  run: ->(_context) {},
  check: ->(_context) { true },
  target_classes: [],
  assume_deadlocked_after_ms: 10
).run
