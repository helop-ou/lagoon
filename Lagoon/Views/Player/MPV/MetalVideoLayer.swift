import QuartzCore

/// CAMetalLayer that mpv's gpu-next output renders into.
///
/// MoltenVK forcefully completes presentation by setting drawableSize to
/// 1×1, which flickers and can wedge the size there — swallow those writes
/// (see mpv-player/mpv#13651; same workaround as the MPVKit demo).
final class MetalVideoLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1, Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}
