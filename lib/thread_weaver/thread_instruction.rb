# typed: strict

module ThreadWeaver
  module ThreadInstruction
    extend T::Sig
    extend T::Helpers
    interface!
    sealed!

    sig { abstract.params(m: Module).returns(T::Boolean) }
    def is_a?(m)
    end
  end

  class PauseAtThreadStart < T::Struct
    include ThreadInstruction
  end

  class ContinueToThreadEnd < T::Struct
    include ThreadInstruction
  end

  class PauseWhenLineCount < T::Struct
    include ThreadInstruction
    extend T::Sig

    const :count, Integer
    const :target_classes, T::Array[Module]

    sig { returns(PauseWhenLineCount) }
    def next
      PauseWhenLineCount.new(
        count: count + 1,
        target_classes: target_classes
      )
    end
  end

  class PauseAtMethodCall < T::Struct
    include ThreadInstruction

    const :klass, Class
    const :method_name, Symbol
  end

  class PauseAtMethodReturn < T::Struct
    include ThreadInstruction

    const :klass, Class
    const :method_name, Symbol
  end

  class PauseAtSourceLine < T::Struct
    include ThreadInstruction
    extend T::Sig

    const :path_suffix, String
    const :line, Integer

    sig { returns(PauseAtSourceLine) }
    def next
      PauseAtSourceLine.new(
        line: line + 1,
        path_suffix: path_suffix
      )
    end
  end
end
