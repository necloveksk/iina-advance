//
//  GLVideoLayer.swift
//  iina
//
//  Created by lhc on 27/1/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa
import OpenGL.GL
import OpenGL.GL3

class GLVideoLayer: CAOpenGLLayer {

  unowned var videoView: VideoView!

  private let mpvGLQueue = DispatchQueue(label: "com.colliderli.iina.mpvgl", qos: .userInteractive)
  private var blocked = false

  private var fbo: GLint = 1

  private var needsMPVRender = false
  private var forceRender = false

  private let asychronousModeLock = Lock()
  private var asychronousModeTimer: Timer?

#if LOG_VIDEO_LAYER
  // For measuring frames per second
  var lastPrintTime = Date().timeIntervalSince1970
  var displayCountTotal: Int = 0
  var displayCountLastPrint: Int = 0
  var canDrawCountTotal: Int = 0
  var canDrawCountLastPrint: Int = 0
  var drawCountTotal: Int = 0
  var drawCountLastPrint: Int = 0
  var forcedCountTotal: Int = 0
  var forcedCountLastPrint: Int = 0
  var lastWidth: Int32 = 0
  var lastHeight: Int32 = 0

  func printStats() {
    let now = Date().timeIntervalSince1970
    let secsSinceLastPrint = now - lastPrintTime
    if secsSinceLastPrint >= 1.0 {  // print at most once per sec
      let displaysSinceLastPrint = displayCountTotal - displayCountLastPrint
      let canDrawCallsSinceLastPrint = canDrawCountTotal - canDrawCountLastPrint
      let drawsSinceLastPrint = drawCountTotal - drawCountLastPrint
      let forcedSinceLastPrint = forcedCountTotal - forcedCountLastPrint

      let fpsDraws = CGFloat(drawsSinceLastPrint) / secsSinceLastPrint
      lastPrintTime = now
      displayCountLastPrint = displayCountTotal
      canDrawCountLastPrint = canDrawCountTotal
      drawCountLastPrint = drawCountTotal
      forcedCountLastPrint = forcedCountTotal
      let viewConstraints = videoView.widthConstraint.isActive ? "\(videoView.widthConstraint.constant.string2f)x\(videoView.heightConstraint.constant.string2f)" : "NA"
      NSLog("FPS: \(fpsDraws.string2f) (\(drawsSinceLastPrint)/\(canDrawCallsSinceLastPrint) requests drawn, \(forcedSinceLastPrint) forced, \(displaysSinceLastPrint) displays over \(secsSinceLastPrint.twoDecimalPlaces)s) Scale: \(contentsScale.string6f), LayerSize: \(Int(frame.size.width))x\(Int(frame.size.height)), LastDrawSize: \(lastWidth)x\(lastHeight), ViewConstraints: \(viewConstraints)")
    }
  }
#endif

  init(videoView: VideoView) {
    super.init()

    self.videoView = videoView
  }

  override init() {
    super.init()
  }

  override convenience init(layer: Any) {
    self.init()

    let previousLayer = layer as! GLVideoLayer

    videoView = previousLayer.videoView
  }

  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
    var attributeList: [CGLPixelFormatAttribute] = [
      kCGLPFADoubleBuffer,
      kCGLPFAAllowOfflineRenderers,
      kCGLPFAColorFloat,
      kCGLPFAColorSize, CGLPixelFormatAttribute(64),
      kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue),
      kCGLPFAAccelerated,
    ]

    if (!Preference.bool(for: .forceDedicatedGPU)) {
      attributeList.append(kCGLPFASupportsAutomaticGraphicsSwitching)
    }

    var pix: CGLPixelFormatObj?
    var npix: GLint = 0

    for index in (0..<attributeList.count).reversed() {
      let attributes = Array(
        attributeList[0...index] + [_CGLPixelFormatAttribute(rawValue: 0)]
      )
      CGLChoosePixelFormat(attributes, &pix, &npix)
      if let pix = pix {
        videoView.player.log.debug("Created OpenGL pixel format with \(attributes)")
        return pix
      }
    }

    Logger.fatal("Cannot create OpenGL pixel format!")
  }

  override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
    let ctx = super.copyCGLContext(forPixelFormat: pf)

    var i: GLint = 1
    CGLSetParameter(ctx, kCGLCPSwapInterval, &i)

    CGLEnable(ctx, kCGLCEMPEngine)

    CGLSetCurrentContext(ctx)
    return ctx
  }

  // MARK: Draw

  override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
#if LOG_VIDEO_LAYER
    canDrawCountTotal += 1

//    if let ts = ts?.pointee {
//      NSLog("CAN_DRAW vidTS: \(ts.videoTime), hostTS: \(ts.hostTime), layerTime: \(t), queue: \(DispatchQueue.currentQueueLabel ?? "nil")")
//    } else {
//      NSLog("CAN_DRAW")
//    }
//    printStats()
#endif
    if forceRender {
      forceRender = false
      return true
    }
    return videoView.player.mpv.shouldRenderUpdateFrame()
  }

  override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
    let mpv = videoView.player.mpv!
    needsMPVRender = false

    glClear(GLbitfield(GL_COLOR_BUFFER_BIT))

    var i: GLint = 0
    glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &i)
    var dims: [GLint] = [0, 0, 0, 0]
    glGetIntegerv(GLenum(GL_VIEWPORT), &dims);

    var flip: CInt = 1

    withUnsafeMutablePointer(to: &flip) { flip in
      if let context = mpv.mpvRenderContext {
        fbo = i != 0 ? i : fbo

#if LOG_VIDEO_LAYER
        lastWidth = Int32(dims[2])
        lastHeight = Int32(dims[3])
        drawCountTotal += 1
        printStats()

//        if let ts = ts?.pointee {
//          NSLog("DRAW fbo: \(fbo) vidTS: \(ts.videoTime), hostTS: \(ts.hostTime) layerTime: \(t)")
//        } else {
//          NSLog("DRAW fbo: \(fbo)")
//        }
#endif
        var data = mpv_opengl_fbo(fbo: Int32(fbo),
                                  w: Int32(dims[2]),
                                  h: Int32(dims[3]),
                                  internal_format: 0)
        withUnsafeMutablePointer(to: &data) { data in
          var params: [mpv_render_param] = [
            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: .init(data)),
            mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: .init(flip)),
            mpv_render_param()
          ]
          mpv_render_context_render(context, &params);
          ignoreGLError()
        }
      }
    }
    glFlush()
  }

  func suspend() {
    asychronousModeTimer?.invalidate()
    /// If this is set to `true` while the video is paused, there is some degree of busy-waiting as the
    /// layer is polled at a high rate about whether it needs to draw. Disable this to save CPU while idle.
    isAsynchronous = false

    blocked = true
  }

  func resume() {
    blocked = false

    drawAsync()
  }

  /// We want `isAsynchronous = true` while executing any animation which causes the layer to resize.
  /// But we don't want to leave this on full-time, because it will result in extra draw requests and may
  /// throw off the timing of each draw.
  func enterAsynchronousMode() {
    asychronousModeLock.withLock{
      asychronousModeTimer?.invalidate()
      if !isAsynchronous {
        videoView.player.log.verbose("Entering asynchronous mode")
      }
      /// Set this to `true` to enable video redraws to match the timing of the view redraw during animations.
      /// This fixes a situation where the layer size may not match the size of its superview at each redraw,
      /// which would cause noticable clipping or wobbling during animations.
      isAsynchronous = true

      asychronousModeTimer = Timer.scheduledTimer(
        timeInterval: AppData.asynchronousModeTimeIntervalSec,
        target: self,
        selector: #selector(self.exitAsynchronousMode),
        userInfo: nil,
        repeats: false
      )
      /// Save some CPU by making this less strict, because we don't really care that much
      asychronousModeTimer?.tolerance = AppData.asynchronousModeTimeIntervalSec * 0.1
    }
  }

  @objc func exitAsynchronousMode() {
    asychronousModeLock.withLock{
      videoView.player.log.verbose("Exiting asynchronous mode")
      isAsynchronous = false
    }
  }

  func drawAsync() {
    guard !blocked else {
      return
    }

    mpvGLQueue.async { [self] in
      draw()
    }
  }

  func draw(forced: Bool = false) {
    videoView.$isUninited.withLock() { isUninited in
      // The properties forceRender and needsMPVRender are always accessed while holding isUninited's
      // lock. This avoids the need for separate locks to avoid data races with these flags. No need
      // to check isUninited at this point.
      needsMPVRender = true
      if forced { forceRender = true }
    }

    // Must not call display while holding isUninited's lock as that method will attempt to acquire
    // the lock and our locks do not support recursion.
    display()

    videoView.$isUninited.withLock() { isUninited in
      guard !isUninited else { return }
      if forced {
        forceRender = false
        return
      }
      guard needsMPVRender else { return }

      if let renderContext = videoView.player.mpv.mpvRenderContext,
         let openGLContext = videoView.player.mpv.openGLContext {
        CGLLockContext(openGLContext)
        defer { CGLUnlockContext(openGLContext) }
        var skip: CInt = 1
        withUnsafeMutablePointer(to: &skip) { skip in
          var params: [mpv_render_param] = [
            mpv_render_param(type: MPV_RENDER_PARAM_SKIP_RENDERING, data: .init(skip)),
            mpv_render_param()
          ]
          mpv_render_context_render(renderContext, &params);
        }
      }
      needsMPVRender = false
    }
  }

  override func display() {
    let needsFlush: Bool = videoView.$isUninited.withLock() { isUninited in
      guard !isUninited else { return false }

      super.display()
      return true
    }

    guard needsFlush else { return }

#if LOG_VIDEO_LAYER
    displayCountTotal += 1
#endif

    // Must not call flush while holding isUninited's lock as that method may call display and our
    // locks do not support recursion.
    CATransaction.flush()
  }

  // MARK: Utils

  /** Check OpenGL error (for debug only). */
  func gle() {
    let e = glGetError()
    print(arc4random())
    switch e {
    case GLenum(GL_NO_ERROR):
      break
    case GLenum(GL_OUT_OF_MEMORY):
      print("GL_OUT_OF_MEMORY")
      break
    case GLenum(GL_INVALID_ENUM):
      print("GL_INVALID_ENUM")
      break
    case GLenum(GL_INVALID_VALUE):
      print("GL_INVALID_VALUE")
      break
    case GLenum(GL_INVALID_OPERATION):
      print("GL_INVALID_OPERATION")
      break
    case GLenum(GL_INVALID_FRAMEBUFFER_OPERATION):
      print("GL_INVALID_FRAMEBUFFER_OPERATION")
      break
    case GLenum(GL_STACK_UNDERFLOW):
      print("GL_STACK_UNDERFLOW")
      break
    case GLenum(GL_STACK_OVERFLOW):
      print("GL_STACK_OVERFLOW")
      break
    default:
      break
    }
  }

  func ignoreGLError() {
    glGetError()
  }
}
