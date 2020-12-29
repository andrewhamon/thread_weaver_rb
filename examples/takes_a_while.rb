class TakesAWhile
  def call(duration_ms:)
    sleep(duration_ms / 1000.0)
  end
end
