# typed: strict

module ThreadWeaver
  class RaceConditionDetectedError < Error; end

  class DeadlockDetectedError < Error; end

  class BlockingSynchronizationDetected < Error; end

  DEADLOCK_MIGHT_BE_CONFIG = T.let(
    "Either there is a deadlock, or assume_deadlocked_after_ms is set too low. Try increasing "\
    "assume_deadlocked_after_ms to a higher value.",
    String
  )

  class IterativeRaceDetector
    extend T::Sig

    sig do
      params(
        setup: T.proc.returns(T.untyped),
        run: T.proc.params(arg0: T.untyped).void,
        check: T.proc.params(arg0: T.untyped).returns(T::Boolean),
        target_classes: T::Array[Module],
        assume_deadlocked_after_ms: Integer,
        run_secondary: T.nilable(T.proc.params(arg0: T.untyped).void),
        expect_nonblocking: T::Boolean
      ).void
    end
    def initialize(setup:, run:, check:, target_classes:, assume_deadlocked_after_ms:, run_secondary: nil, expect_nonblocking: false)
      @setup_blk = T.let(setup, T.proc.returns(T.untyped))
      @check_blk = T.let(check, T.proc.params(arg0: T.untyped).returns(T::Boolean))
      @target_classes = T.let(target_classes, T::Array[Module])
      @expect_nonblocking = T.let(expect_nonblocking, T::Boolean)

      @run_blk = T.let(run, T.proc.params(arg0: T.untyped).void)
      # Secondary is optional as the common case will be testing two identical blocks of code
      @run_secondary_blk = T.let(run_secondary || run, T.proc.params(arg0: T.untyped).void)

      @assume_deadlocked_after = T.let(assume_deadlocked_after_ms / 1000.0, Float)

      @scenarios_run = T.let(0, Integer)
      @secondary_deadlocked_count = T.let(0, Integer)
    end

    sig { void }
    def run
      check_if_can_run_standalone(@run_blk, "run")
      if @run_secondary_blk != @run_blk
        check_if_can_run_standalone(@run_secondary_blk, "run_secondary")
      end

      hold_primary_at_line_count = -1
      done = T.let(false, T::Boolean)

      error_encountered = T.let(nil, T.nilable(Exception))

      until done
        Timeout.timeout(2 * @assume_deadlocked_after) do
          hold_primary_at_line_count += 1

          context = @setup_blk.call

          primary_thread = ControllableThread.new(context, name: "primary_thread", &@run_blk)

          # Pause the primary thread after it executes hold_primary_at_line_count number of lines
          primary_thread.set_and_wait_for_next_instruction(
            PauseWhenLineCount.new(
              count: hold_primary_at_line_count,
              target_classes: @target_classes
            )
          )

          # Start secondary thread and instruct it to run until completion. The primary thread is
          # still paused part-way through its execution
          secondary_thread = ControllableThread.new(context, name: "secondary_thread", &@run_secondary_blk)
          secondary_thread.set_next_instruction(ContinueToThreadEnd.new)

          if check_for_deadlock(secondary_thread)
            # At this point, it appears that the secondary thread is deadlocked. This could be
            # because of a true deadlock, but this also is expected to happen even in thread-safe
            # code that uses blocking locks. If blocking locks are used then its quite likely that
            # pausing the primary thread at certain points might would block the secondary thread.
            # For that reason, this isn't considered an outright error.
            @secondary_deadlocked_count += 1
            primary_thread.set_and_wait_for_next_instruction(ContinueToThreadEnd.new)

            if @expect_nonblocking
              error_encountered ||= BlockingSynchronizationDetected.new(
                "Deadlock detected, but expect_nonblocking was set to true. Make sure you aren't "\
                "blocking waiting for a lock."
              )
            end
          end

          # Wait for the secondary thread to complete, taking note of any errors
          begin
            secondary_thread.join
          rescue => e
            # Defer exception until after the primary thread gets a chance to join, to avoid leaking
            # threads
            error_encountered ||= e
          end

          # Only now that the secondary thread has completed, release the primary thread
          primary_thread.set_and_wait_for_next_instruction(ContinueToThreadEnd.new)

          begin
            primary_thread.join
            @scenarios_run += 1
          rescue ThreadCompletedEarlyError
            # ThreadCompletedEarlyError will occur if the primary thread never successfully paused
            # at the specified location. This happens normally, when hold_primary_at_line_count is
            # incremented until it exceeds the number of lines actually executed in the primary
            # thread. Once that point is reached, the primary thread will never get caught on the
            # PauseWhenLineCount instruction. ControllableThread signals failures to execute a given
            # instruction by returning a ThreadCompletedEarlyError, which we use as a signal to stop
            # probing for race conditions. When this happens, we have done a race condition check
            # with the primary thread paused at every possible location in target_classes, assuming
            # the code in question is deterministic, so there is nothing left to check.
            done = true
          end

          # Now that both threads have had a chance to join, raise any errors discovered
          raise error_encountered if error_encountered

          check_passed = @check_blk.call(context)

          unless check_passed
            raise RaceConditionDetectedError.new("Test failed")
          end
        end
      end

      if @secondary_deadlocked_count == @scenarios_run
        message = "In every scenario, the secondary thread was assumed deadlocked while the "\
                  "primary thread was paused. #{DEADLOCK_MIGHT_BE_CONFIG}"
        raise DeadlockDetectedError.new(message)
      end
    end

    sig { params(blk: T.proc.params(arg0: T.untyped).void, name: String).void }
    def check_if_can_run_standalone(blk, name)
      context = @setup_blk.call
      thread = ControllableThread.new(context, name: name, &blk)
      thread.set_next_instruction(ContinueToThreadEnd.new)

      if check_for_deadlock(thread)
        thread.kill
        message = "#{name} appears to be deadlocked when running alone, with no other concurrent "\
                  "threads. #{DEADLOCK_MIGHT_BE_CONFIG}"

        raise DeadlockDetectedError.new(message)
      end

      check_passed = @check_blk.call(context)

      unless check_passed
        message = "#{name} failed check when running alone, with no other concurrent threads. "\
                  "Your check logic may be flawed."
        raise RaceConditionDetectedError.new(message)
      end
    end

    private

    sig { params(thread: ControllableThread).returns(T::Boolean) }
    def check_for_deadlock(thread)
      started_at = Time.now

      while thread.alive? && (Time.now - started_at) < @assume_deadlocked_after
        Thread.pass
      end

      thread.alive?
    end
  end
end
