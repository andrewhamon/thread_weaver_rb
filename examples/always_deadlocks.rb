# This is a bit of a contrived example, but this class always deadlocks if the secondary is run
# without eventually running the primary.
class AlwaysDeadlocks
  def initialize
    @primary_has_run = false
  end

  def call(is_primary:)
    if is_primary
      @primary_has_run = true
    else
      Thread.pass until @primary_has_run
    end
  end
end
