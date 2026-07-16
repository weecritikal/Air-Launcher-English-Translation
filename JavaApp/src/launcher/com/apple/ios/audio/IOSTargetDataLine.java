package com.apple.ios.audio;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import javax.sound.sampled.*;
public class IOSTargetDataLine implements TargetDataLine {
    private AudioFormat format;
    private int bufferSize;
    private boolean open, running;
    private long nativeHandle;
    private final List<LineListener> listeners = new CopyOnWriteArrayList<>();
    @Override
    public void open() throws LineUnavailableException {
        throw new LineUnavailableException("Use open(AudioFormat) instead");
    }
    @Override
    public void open(AudioFormat format, int bufferSize) throws LineUnavailableException {
        if (open) close();
        if (format.getEncoding() != AudioFormat.Encoding.PCM_SIGNED
                || format.getSampleSizeInBits() != 16
                || format.getChannels() != 1) {
            throw new LineUnavailableException("Unsupported format: " + format);
        }
        this.format = format;
        this.bufferSize = Math.max(bufferSize, 4096);
        nativeHandle = NativeAudioCapture.init(
            (int) format.getSampleRate(),
            format.getChannels(),
            format.getSampleSizeInBits(),
            format.isBigEndian()
        );
        if (nativeHandle == 0) {
            throw new LineUnavailableException("Failed to initialize native audio capture");
        }
        open = true;
        fireEvent(LineEvent.Type.OPEN);
    }
    @Override
    public void open(AudioFormat format) throws LineUnavailableException {
        open(format, 4096);
    }
    @Override
    public void close() {
        if (!open) return;
        if (running) stop();
        open = false;
        if (nativeHandle != 0) {
            NativeAudioCapture.release(nativeHandle);
            nativeHandle = 0;
        }
        fireEvent(LineEvent.Type.CLOSE);
    }
    @Override
    public boolean isOpen() {
        return open;
    }
    @Override
    public void start() {
        if (!open || running) return;
        running = true;
        NativeAudioCapture.start(nativeHandle);
        fireEvent(LineEvent.Type.START);
    }
    @Override
    public void stop() {
        if (!running) return;
        running = false;
        NativeAudioCapture.stop(nativeHandle);
        fireEvent(LineEvent.Type.STOP);
    }
    @Override
    public boolean isRunning() {
        return running;
    }
    @Override
    public boolean isActive() {
        return running;
    }
    @Override
    public AudioFormat getFormat() {
        return format;
    }
    @Override
    public int getBufferSize() {
        return bufferSize;
    }
    @Override
    public int available() {
        if (!open) return 0;
        return NativeAudioCapture.available(nativeHandle);
    }
    @Override
    public int read(byte[] b, int off, int len) {
        if (!open || !running) return -1;
        return NativeAudioCapture.read(nativeHandle, b, off, len);
    }
    public int remaining() {
        return 0;
    }
    @Override
    public float getLevel() {
        return AudioSystem.NOT_SPECIFIED;
    }
    @Override
    public void drain() {
    }
    @Override
    public void flush() {
    }
    @Override
    public long getLongFramePosition() {
        return 0;
    }
    @Override
    public int getFramePosition() {
        return 0;
    }
    @Override
    public long getMicrosecondPosition() {
        return 0;
    }
    @Override
    public void addLineListener(LineListener listener) {
        if (!listeners.contains(listener)) listeners.add(listener);
    }
    @Override
    public void removeLineListener(LineListener listener) {
        listeners.remove(listener);
    }
    @Override
    public Control[] getControls() {
        return new Control[0];
    }
    @Override
    public boolean isControlSupported(Control.Type control) {
        return false;
    }
    @Override
    public Control getControl(Control.Type control) {
        throw new IllegalArgumentException("Unsupported control: " + control);
    }
    @Override
    public Line.Info getLineInfo() {
        return new DataLine.Info(TargetDataLine.class, format, bufferSize);
    }
    private void fireEvent(LineEvent.Type type) {
        LineEvent event = new LineEvent(this, type, getLongFramePosition());
        for (LineListener l : listeners) {
            l.update(event);
        }
    }
}
