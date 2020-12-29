# typed: strict

module ThreadWeaver
  class RaceConditionDetectedError < Error; end

  class IterativeRaceDetector
    extend T::Sig

    sig do
      params(
        setup: T.proc.returns(T.untyped),
        run: T.proc.params(arg0: T.untyped).void,
        check: T.proc.params(arg0: T.untyped).returns(T::Boolean),
        target_classes: T::Array[Module],
        assume_deadlocked_after_ms: Integer,
        run_secondary: T.nilable(T.proc.params(arg0: T.untyped).void)
      ).void
    end
    def initialize(setup:, run:, check:, target_classes:, assume_deadlocked_after_ms:, run_secondary: nil)
      @setup_blk = T.let(setup, T.proc.returns(T.untyped))
      @check_blk = T.let(check, T.proc.params(arg0: T.untyped).returns(T::Boolean))
      @target_classes = T.let(target_classes, T::Array[Module])

      @primary_thread_blk = T.let(run, T.proc.params(arg0: T.untyped).void)
      # Secondary is optional as the common case will be testing two identical blocks of code
      @secondary_thread_blk = T.let(run_secondary || run, T.proc.params(arg0: T.untyped).void)

      @assume_deadlocked_after = T.let(assume_deadlocked_after_ms / 1000.0, Float)
    end

    sig { void }
    def run
      hold_main_at_line_count = -1
      done = T.let(false, T::Boolean)

      ControllableThread.with_thread_control_enabled do
        until done
          Timeout.timeout(2 * @assume_deadlocked_after) do
            hold_main_at_line_count += 1

            context = @setup_blk.call

            primary_thread = ControllableThread.new(context, name: "primary_thread", &@primary_thread_blk)
            primary_thread.report_on_exception = false

            primary_thread.set_and_wait_for_next_instruction(
              PauseWhenLineCount.new(
                count: hold_main_at_line_count,
                target_classes: @target_classes
              )
            )

            secondary_thread = ControllableThread.new(context, name: "secondary_thread", &@secondary_thread_blk)

            secondary_thread.set_next_instruction(ContinueToThreadEnd.new)

            assumed_to_be_deadlocked = wait_for_thread_to_complete(secondary_thread)

            if assumed_to_be_deadlocked
              # If at this point the second thread has not completed, assume that it is waiting on a
              # lock held by the primary thread. In that case, we can cancel this test run. If this
              # happens for every test run, though, there might be a problem.

              primary_thread.set_and_wait_for_next_instruction(ContinueToThreadEnd.new)
            end

            secondary_thread.join

            primary_thread.set_and_wait_for_next_instruction(ContinueToThreadEnd.new)

            begin
              primary_thread.join
            rescue ThreadCompletedEarlyError
              done = true
            end

            check_passed = @check_blk.call(context)

            unless check_passed
              raise RaceConditionDetectedError.new("Test failed")
            end
          end
        end
      end
    end

    private

    sig { params(thread: ControllableThread).void }
    def wait_for_thread_to_complete(thread)
      started_at = Time.now

      while (Time.now - started_at) < @assume_deadlocked_after
        Thread.pass
      end

      thread.alive?
    end
  end
end
