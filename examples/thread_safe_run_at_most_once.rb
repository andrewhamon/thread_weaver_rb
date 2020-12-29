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
