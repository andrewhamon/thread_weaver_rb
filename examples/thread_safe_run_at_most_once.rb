# This is a thread-safe version of ThreadUnsafeRunAtMostOnce. It wraps the call with a mutex which
# guarantees that the critical section is only ever run in one thread at a time, thereby making this
# safe to use and call from multiple threads.
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
