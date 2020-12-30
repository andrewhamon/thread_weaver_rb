# This is a non-blocking version of ThreadSafeRunAtMostOnce. It is still thread-safe, but instead of
# blocking while waiting for the lock, it simply does nothing. If the lock can not be immediately
# acquired, then another thread must have acquired it which means the block already has or will soon
# be run.
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
