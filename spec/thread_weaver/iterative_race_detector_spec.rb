# typed: false
# frozen_string_literal: true

class ThreadSafeRunAtMostOnce
  def initialize(&blk)
    @blk = blk
    @ran = false
    @mutex = Mutex.new
  end

  def call
    @mutex.synchronize do
      unless @ran
        @ran = true
        @blk.call
      end
    end
  end
end

class ThreadUnsafeRunAtMostOnce
  def initialize(&blk)
    @blk = blk
    @ran = false
  end

  def call
    unless @ran
      @ran = true
      @blk.call
    end
  end
end

RSpec.describe ThreadWeaver::IterativeRaceDetector do
  context "running ThreadSafeRunAtMostOnce concurrently" do
    it "doesn't deadlock" do
      ThreadWeaver::IterativeRaceDetector.new(
        setup: -> {
          context = {invocations: 0}
          at_most_once = ThreadSafeRunAtMostOnce.new {
            context[:invocations] += 1
          }

          context[:at_most_once] = at_most_once
          context
        },
        run: ->(context) { context[:at_most_once].call },
        check: ->(context) { context[:invocations] == 1 },
        target_classes: [ThreadSafeRunAtMostOnce],
        assume_deadlocked_after_ms: 25
      ).run
    end
  end

  context "running ThreadUnsafeRunAtMostOnce concurrently" do
    it "discovers the race condition and throws an error" do
      expect {
        ThreadWeaver::IterativeRaceDetector.new(
          setup: -> {
            context = {invocations: 0}
            at_most_once = ThreadUnsafeRunAtMostOnce.new {
              context[:invocations] += 1
            }

            context[:at_most_once] = at_most_once
            context
          },
          run: ->(context) { context[:at_most_once].call },
          check: ->(context) { context[:invocations] == 1 },
          target_classes: [ThreadUnsafeRunAtMostOnce],
          assume_deadlocked_after_ms: 25
        ).run
      }.to raise_error(ThreadWeaver::RaceConditionDetectedError)
    end
  end
end
