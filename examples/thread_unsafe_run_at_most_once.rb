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
