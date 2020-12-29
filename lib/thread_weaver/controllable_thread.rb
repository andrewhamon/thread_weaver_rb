# typed: strict

module ThreadWeaver
  class ThreadCompletedEarlyError < Error; end

  class ControllableThread < Thread
    extend T::Sig

    sig { params(blk: T.proc.void).void }
    def self.with_thread_control_enabled(&blk)
      tracer = TracePoint.new(:line, :call, :return, :b_call, :b_return, :thread_begin, :thread_end, :c_call, :c_return) { |tp|
        current_thread = Thread.current
        if current_thread.is_a?(ControllableThread)
          current_thread.handle_trace_point(tp)
        end
      }
      tracer.enable

      yield
    ensure
      tracer&.disable
    end

    sig { returns(String) }
    attr_reader :last_trace_point_summary

    sig do
      params(context: T.untyped, name: String, blk: T.proc.params(arg0: T.untyped).void).void
    end
    def initialize(context, name:, &blk)
      @waiting = T.let(false, T::Boolean)
      @execution_counter = T.let(-1, Integer)
      @last_trace_point_summary = T.let("<no traces detected>", String)
      @line_counts_by_class = T.let({}, T::Hash[Module, Integer])
      @current_instruction = T.let(PauseAtThreadStart.new, ThreadInstruction)

      self.name = name

      super do
        blk.call(context)
        handle_thread_end
      end

      wait_until_next_instruction_complete
    end

    sig { void }
    def wait_until_next_instruction_complete
      assert_self_is_not_current_thread

      do_nothing while alive? && !@waiting
    end

    sig { void }
    def release
      assert_self_is_not_current_thread

      @waiting = false
    end

    sig { void }
    def next
      assert_self_is_not_current_thread

      case @current_instruction
      when PauseWhenLineCount, PauseAtSourceLine
        set_next_instruction(
          @current_instruction.next
        )
      else
        raise "Next is only supported when paused on a #{PauseWhenLineCount.name} or a #{PauseAtSourceLine} instruction "
      end
    end

    sig { params(instruction: ThreadInstruction).void }
    def set_next_instruction(instruction)
      assert_self_is_not_current_thread
      @current_instruction = instruction
      release
    end

    sig { params(instruction: ThreadInstruction).void }
    def set_and_wait_for_next_instruction(instruction)
      set_next_instruction(instruction)
      wait_until_next_instruction_complete
    end

    sig { params(tp: TracePoint).void }
    def handle_trace_point(tp)
      event = T.let(tp.event, Symbol)
      klass = T.let(tp.defined_class, T.nilable(Module))
      path = T.let(tp.path, T.nilable(String))
      line = T.let(tp.lineno, T.nilable(Integer))
      method_name = T.let(tp.method_id, T.nilable(Symbol))

      @last_trace_point_summary = "#{event} #{klass}##{method_name} #{path}#L#{line}"

      if klass
        current_count = @line_counts_by_class.fetch(klass, 0)
        @line_counts_by_class[klass] = (current_count + 1)
      end

      case @current_instruction
      when PauseAtThreadStart
        if event == :thread_begin
          wait_until_released
        end
      when ContinueToThreadEnd
        # do nothing
      when PauseWhenLineCount
        current_count = @current_instruction.target_classes.map { |klass| @line_counts_by_class.fetch(klass, 0) }.sum
        required_count = @current_instruction.count
        if required_count == current_count
          wait_until_released
        end
      when PauseAtMethodCall
        if @current_instruction.klass == klass && @current_instruction.method_name == method_name
          wait_until_released
        end
      when PauseAtMethodReturn
        if @current_instruction.klass == klass && @current_instruction.method_name == method_name
          wait_until_released
        end
      when PauseAtSourceLine
        if path&.end_with?(@current_instruction.path_suffix) && @current_instruction.line == line
          wait_until_released
        end
      else
        T.absurd(@current_instruction)
      end
    end

    sig { override.returns(ControllableThread) }
    def join
      while alive?
        release
        do_nothing
      end
      super()
    end

    private

    sig { void }
    def handle_thread_end
      assert_self_is_current_thread
      unless @current_instruction.is_a?(ContinueToThreadEnd)
        raise ThreadCompletedEarlyError.new("Thread #{name} completed while attempting to match instruction #{@current_instruction}")
      end
    end

    sig { void }
    def wait_until_released
      @waiting = true
      do_nothing while @waiting
    end

    sig { void }
    def do_nothing
      Thread.pass
    end

    sig { void }
    def assert_self_is_current_thread
      raise "illegal call from thread other than self" unless Thread.current == self
    end

    sig { void }
    def assert_self_is_not_current_thread
      raise "illegal call from self" unless Thread.current != self
    end
  end
end
