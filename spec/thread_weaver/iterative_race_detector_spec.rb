# typed: false
# frozen_string_literal: true

require_relative "../../examples/thread_safe_run_at_most_once"
require_relative "../../examples/thread_safe_nonblocking_run_at_most_once"
require_relative "../../examples/thread_unsafe_run_at_most_once"
require_relative "../../examples/always_deadlocks"
require_relative "../../examples/takes_a_while"

require "securerandom"

RSpec.describe ThreadWeaver::IterativeRaceDetector do
  # Examples should never leak threads
  after(:each) do
    Thread.pass
    expect(Thread.list.length).to eq(1)
  end

  ##################################################################################################
  ################# IF YOU ARE DEBUGGING INTERMITTENT TEST FAILURES, READ BELOW | ##################
  ############################################################################# V ##################
  # This value has a significant impact on how quickly tests run. 25ms seems to be a sweet spot,   #
  # at least in this author's development environment, where deadlock false positives occur very   #
  # infrequently. If tests are throwing deadlock errors intermittently, try increasing this value. #
  ##################################################################################################
  let(:assume_deadlocked_after_ms) { 25 }

  let(:random_context) { SecureRandom.uuid }
  it "passes calculated context to the run block" do
    ThreadWeaver::IterativeRaceDetector.new(
      setup: -> { random_context },
      run: ->(context) { expect(context).to eq(random_context) },
      check: ->(_context) { true },
      target_classes: [],
      assume_deadlocked_after_ms: assume_deadlocked_after_ms
    ).run
  end

  it "passes calculated context to the check block" do
    ThreadWeaver::IterativeRaceDetector.new(
      setup: -> { random_context },
      run: ->(_context) { true },
      check: ->(context) { expect(context).to eq(random_context) },
      target_classes: [],
      assume_deadlocked_after_ms: assume_deadlocked_after_ms
    ).run
  end

  it "allows the context to be mutated by the run block" do
    duplicated_random_context = random_context.dup

    ThreadWeaver::IterativeRaceDetector.new(
      setup: -> { random_context },
      run: ->(context) {
        expect(context).to eq(random_context)
        context.upcase!
      },
      check: ->(context) {
        expect(context).to_not eq(duplicated_random_context)
        expect(context).to eq(duplicated_random_context.upcase)
      },
      target_classes: [],
      assume_deadlocked_after_ms: assume_deadlocked_after_ms
    ).run
  end

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
        check: ->(context) { expect(context[:invocations]).to eq(1) },
        target_classes: [ThreadSafeRunAtMostOnce],
        assume_deadlocked_after_ms: assume_deadlocked_after_ms
      ).run
    end

    context "expect_nonblocking is true" do
      it "detects that this is a blocking implementation and raises an error" do
        expect {
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
            check: ->(context) { expect(context[:invocations]).to eq(1) },
            target_classes: [ThreadSafeRunAtMostOnce],
            assume_deadlocked_after_ms: assume_deadlocked_after_ms,
            expect_nonblocking: true
          ).run
        }.to raise_error(ThreadWeaver::BlockingSynchronizationDetected)
      end
    end
  end

  context "running ThreadSafeNonblockingRunAtMostOnce concurrently" do
    context "expect_nonblocking is true" do
      it "detects no errors" do
        ThreadWeaver::IterativeRaceDetector.new(
          setup: -> {
            context = {invocations: 0}
            at_most_once = ThreadSafeNonblockingRunAtMostOnce.new {
              context[:invocations] += 1
            }

            context[:at_most_once] = at_most_once
            context
          },
          run: ->(context) { context[:at_most_once].call },
          check: ->(context) { expect(context[:invocations]).to eq(1) },
          target_classes: [ThreadSafeNonblockingRunAtMostOnce],
          assume_deadlocked_after_ms: assume_deadlocked_after_ms,
          expect_nonblocking: true
        ).run
      end
    end
  end

  context "running ThreadUnsafeRunAtMostOnce concurrently" do
    it "discovers the race condition and raises a RaceConditionDetectedError" do
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
          assume_deadlocked_after_ms: assume_deadlocked_after_ms
        ).run
      }.to raise_error(ThreadWeaver::RaceConditionDetectedError)
    end
  end

  context "running AlwaysDeadlocks concurrently" do
    it "detects that it always deadlocks and raises a DeadlockDetectedError" do
      expect {
        ThreadWeaver::IterativeRaceDetector.new(
          setup: -> { AlwaysDeadlocks.new },
          run: ->(always_deadlocks) { always_deadlocks.call(is_primary: true) },
          run_secondary: ->(always_deadlocks) { always_deadlocks.call(is_primary: false) },
          check: ->(_always_deadlocks) { true },
          target_classes: [AlwaysDeadlocks],
          assume_deadlocked_after_ms: assume_deadlocked_after_ms
        ).run
      }.to raise_error(ThreadWeaver::DeadlockDetectedError)
    end
  end

  context "running TakesAWhile concurrently" do
    let(:run_duration) { assume_deadlocked_after_ms * 2 }
    context "assume_deadlocked_after_ms is set to a low value" do
      it "erroneously detects a deadlock but suggests it might be due to configuration" do
        expect {
          ThreadWeaver::IterativeRaceDetector.new(
            setup: -> { TakesAWhile.new },
            run: ->(takes_a_while) { takes_a_while.call(duration_ms: run_duration) },
            check: ->(_takes_a_while) { true },
            target_classes: [TakesAWhile],
            assume_deadlocked_after_ms: assume_deadlocked_after_ms
          ).run
        }.to raise_error(ThreadWeaver::DeadlockDetectedError, /Try increasing assume_deadlocked_after_ms to a higher value/)
      end
    end

    context "assume_deadlocked_after_ms is set to an appropriate value" do
      let(:run_duration) { assume_deadlocked_after_ms / 2 }
      it "detects no errors" do
        ThreadWeaver::IterativeRaceDetector.new(
          setup: -> { TakesAWhile.new },
          run: ->(takes_a_while) { takes_a_while.call(duration_ms: run_duration) },
          check: ->(_takes_a_while) { true },
          target_classes: [TakesAWhile],
          assume_deadlocked_after_ms: assume_deadlocked_after_ms
        ).run
      end
    end

    context "exception is thrown during setup" do
      it "passes the error through" do
        expect {
          ThreadWeaver::IterativeRaceDetector.new(
            setup: -> { raise "This should be passed through" },
            run: ->(_context) {},
            check: ->(_context) { true },
            target_classes: [],
            assume_deadlocked_after_ms: assume_deadlocked_after_ms
          ).run
        }.to raise_error(/This should be passed through/)
      end
    end

    context "exception is thrown during run" do
      it "passes the error through" do
        expect {
          ThreadWeaver::IterativeRaceDetector.new(
            setup: -> {},
            run: ->(_context) { raise "This should be passed through" },
            check: ->(_context) { true },
            target_classes: [],
            assume_deadlocked_after_ms: assume_deadlocked_after_ms
          ).run
        }.to raise_error(/This should be passed through/)
      end
    end

    context "exception is thrown during check" do
      it "passes the error through" do
        expect {
          ThreadWeaver::IterativeRaceDetector.new(
            setup: -> {},
            run: ->(_context) {},
            check: ->(_context) { raise "This should be passed through" },
            target_classes: [],
            assume_deadlocked_after_ms: assume_deadlocked_after_ms
          ).run
        }.to raise_error(/This should be passed through/)
      end
    end

    context "the check is always false" do
      it "provides a hint that the check may be flawed" do
        expect {
          ThreadWeaver::IterativeRaceDetector.new(
            setup: -> {},
            run: ->(_context) {},
            check: ->(_context) { false },
            target_classes: [],
            assume_deadlocked_after_ms: assume_deadlocked_after_ms
          ).run
        }.to raise_error(ThreadWeaver::RaceConditionDetectedError, /Your check logic may be flawed/)
      end
    end
  end
end
