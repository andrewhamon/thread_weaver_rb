# This is a naively written routine whose intended purpose is to run the provided block at most
# once. In a single-threaded application this should work just fine, but if an instance of this
# class is shared among several threads who all try to invoke call on it, it will eventually fail at
# its intended purpose and execute the provided block more than once.
class ThreadUnsafeRunAtMostOnce
  def initialize(&blk)
    @blk = blk
    @ran = false
  end

  def call
    unless @ran
      @ran = true
      @blk.call
    end
  end
end
