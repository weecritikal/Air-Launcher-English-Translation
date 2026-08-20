package org.lwjgl.glfw;

import java.util.*;
import net.kdt.pojavlaunch.Tools;

public class GLFWWindowProperties {
    public int width, height;
    public float x, y;
    public CharSequence title;
    public boolean shouldClose, isInitialSizeCalled, isCursorEntered;
    public long monitor;
    /** Whatever glfwSetWindowUserPointer was given. Mods store a handle here and expect it back. */
    public long userPointer;
    public Map<Integer, Integer> inputModes = new HashMap<>();
    public Map<Integer, Integer> windowAttribs = new HashMap<>();
    
    @Override
    public String toString() {
        return "width=" + width + ", " +
          "height=" + height + ", " +
          "x=" + x + ", " +
          "y=" + y + ", ";
    }
}
