class ThreadSafeNonblockingRunAtMostOnce
  def initialize(&blk)
    @blk = blk
    @ran = false
    @mutex = Mutex.new
  end

  def call
    lock_acquired = @mutex.try_lock
    if lock_acquired
      unless @ran
        @ran = true
        @blk.call
      end
    end
  ensure
    @mutex.unlock if lock_acquired
  end
end
