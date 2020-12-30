# This is perfectly thread safe and "nonblocking", just kinda slow. It is used to simulate expensive
# computations.
class TakesAWhile
  def call(duration_ms:)
    sleep(duration_ms / 1000.0)
  end
end
