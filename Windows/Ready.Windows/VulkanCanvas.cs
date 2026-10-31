// SPDX-License-Identifier: GPL-3.0-only
using System.Drawing.Imaging;
using System.Numerics;
using System.Reflection;
using System.Runtime.InteropServices;
using Veldrid;
using Buffer = Veldrid.DeviceBuffer;
using PixelFormat = Veldrid.PixelFormat;

namespace Ready.Windows;

// GDI+ is used only to rasterize text/paths, like CoreGraphics on macOS.
// All presentation and canvas motion use this Vulkan graphics pipeline. No backend fallback.
internal sealed class VulkanCanvas : IDisposable
{
    private readonly GraphicsDevice device;
    private readonly CommandList commands;
    private readonly ResourceLayout layout;
    private readonly Buffer uniforms;
    private readonly Shader[] shaders;
    private readonly Dictionary<PixelFormat, Pipeline> pipelines = [];
    private Veldrid.Texture? texture;
    private TextureView? view;
    private ResourceSet? resources;
    public string DeviceName => device.DeviceName;
    public string Backend => device.BackendType.ToString();
    public long CanvasBytes => texture is null ? 0 : (long)texture.Width * texture.Height * 4;
    public int Submitted { get; private set; }
    public VulkanCanvas(nint window = 0, int width = 0, int height = 0)
    {
        var options = new GraphicsDeviceOptions(false) { PreferStandardClipSpaceYDirection = true, PreferDepthRangeZeroToOne = true };
        device = window == 0 ? GraphicsDevice.CreateVulkan(options) : GraphicsDevice.CreateVulkan(options,
            new SwapchainDescription(SwapchainSource.CreateWin32(window, Marshal.GetHINSTANCE(typeof(VulkanCanvas).Module)),
                (uint)width, (uint)height, null, true, false));
        var factory = device.ResourceFactory;
        commands = factory.CreateCommandList();
        layout = factory.CreateResourceLayout(new ResourceLayoutDescription(
            new ResourceLayoutElementDescription("image", ResourceKind.TextureReadOnly, ShaderStages.Fragment),
            new ResourceLayoutElementDescription("imageSampler", ResourceKind.Sampler, ShaderStages.Fragment),
            new ResourceLayoutElementDescription("Motion", ResourceKind.UniformBuffer, ShaderStages.Fragment)));
        uniforms = factory.CreateBuffer(new BufferDescription(16, BufferUsage.UniformBuffer));
        shaders = [factory.CreateShader(new ShaderDescription(ShaderStages.Vertex, ShaderBytes("canvas.vert.spv"), "main")),
            factory.CreateShader(new ShaderDescription(ShaderStages.Fragment, ShaderBytes("canvas.frag.spv"), "main"))];
    }
    private static byte[] ShaderBytes(string name)
    {
        var assembly = Assembly.GetExecutingAssembly();
        using var stream = assembly.GetManifestResourceStream(assembly.GetManifestResourceNames().Single(n => n.EndsWith(name, StringComparison.Ordinal)))!;
        using var memory = new MemoryStream(); stream.CopyTo(memory); return memory.ToArray();
    }
    private Pipeline Pipeline(Framebuffer target)
    {
        var format = target.ColorTargets[0].Target.Format;
        if (pipelines.TryGetValue(format, out var existing)) return existing;
        var description = new GraphicsPipelineDescription(BlendStateDescription.SingleOverrideBlend, DepthStencilStateDescription.Disabled,
            RasterizerStateDescription.CullNone, PrimitiveTopology.TriangleList,
            new ShaderSetDescription([], shaders, [new SpecializationConstant(0, device.IsClipSpaceYInverted)]), [layout], target.OutputDescription);
        return pipelines[format] = device.ResourceFactory.CreateGraphicsPipeline(description);
    }
    private void Upload(Bitmap raster)
    {
        if (texture is null || texture.Width != raster.Width || texture.Height != raster.Height)
        {
            ReleaseCanvas();
            texture = device.ResourceFactory.CreateTexture(TextureDescription.Texture2D((uint)raster.Width, (uint)raster.Height,
                1, 1, PixelFormat.B8_G8_R8_A8_UNorm, TextureUsage.Sampled));
            view = device.ResourceFactory.CreateTextureView(texture);
            resources = device.ResourceFactory.CreateResourceSet(new ResourceSetDescription(layout, view, device.LinearSampler, uniforms));
        }
        var locked = raster.LockBits(new Rectangle(0, 0, raster.Width, raster.Height), ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
        try
        {
            if (locked.Stride != raster.Width * 4) throw new InvalidOperationException("Raster BGRA non contiguo.");
            device.UpdateTexture(texture, locked.Scan0, (uint)(locked.Stride * raster.Height), 0, 0, 0, (uint)raster.Width, (uint)raster.Height, 1, 0, 0);
        }
        finally { raster.UnlockBits(locked); }
    }
    private void Encode(Framebuffer target, Vector4 motion)
    {
        device.UpdateBuffer(uniforms, 0, motion);
        commands.Begin(); commands.SetFramebuffer(target); commands.SetFullViewports(); commands.SetFullScissorRects();
        commands.SetPipeline(Pipeline(target)); commands.SetGraphicsResourceSet(0, resources!); commands.Draw(3); commands.End();
        device.SubmitCommands(commands); Submitted++;
    }
    public void Present(Bitmap raster, Vector4? motion = null)
    {
        Upload(raster); Encode(device.MainSwapchain.Framebuffer, motion ?? new Vector4(0, 0, 1, 0));
        device.SwapBuffers(); device.WaitForIdle();
    }
    public Bitmap Readback(Bitmap raster, Vector4? motion = null)
    {
        Upload(raster);
        var factory = device.ResourceFactory;
        using var target = factory.CreateTexture(TextureDescription.Texture2D((uint)raster.Width, (uint)raster.Height,
            1, 1, PixelFormat.B8_G8_R8_A8_UNorm, TextureUsage.RenderTarget));
        using var staging = factory.CreateTexture(TextureDescription.Texture2D((uint)raster.Width, (uint)raster.Height,
            1, 1, PixelFormat.B8_G8_R8_A8_UNorm, TextureUsage.Staging));
        using var framebuffer = factory.CreateFramebuffer(new FramebufferDescription(null, target));
        Encode(framebuffer, motion ?? new Vector4(0, 0, 1, 0));
        commands.Begin(); commands.CopyTexture(target, staging); commands.End(); device.SubmitCommands(commands); device.WaitForIdle();
        var mapped = device.Map(staging, MapMode.Read);
        var result = new Bitmap(raster.Width, raster.Height, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
        try
        {
            var locked = result.LockBits(new Rectangle(0, 0, result.Width, result.Height), ImageLockMode.WriteOnly, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
            try
            {
                var row = new byte[result.Width * 4];
                for (int y = 0; y < result.Height; y++)
                {
                    Marshal.Copy(mapped.Data + y * (int)mapped.RowPitch, row, 0, row.Length);
                    Marshal.Copy(row, 0, locked.Scan0 + y * locked.Stride, row.Length);
                }
            }
            finally { result.UnlockBits(locked); }
        }
        catch { result.Dispose(); throw; }
        finally { device.Unmap(staging); }
        return result;
    }
    public void Resize(int width, int height) { if (width > 0 && height > 0) { device.WaitForIdle(); device.MainSwapchain.Resize((uint)width, (uint)height); } }
    public void ReleaseCanvas()
    {
        device.WaitForIdle(); resources?.Dispose(); resources = null; view?.Dispose(); view = null; texture?.Dispose(); texture = null;
    }
    public void Dispose()
    {
        ReleaseCanvas(); foreach (var pipeline in pipelines.Values) pipeline.Dispose();
        foreach (var shader in shaders) shader.Dispose(); uniforms.Dispose(); layout.Dispose(); commands.Dispose(); device.Dispose();
    }
}
