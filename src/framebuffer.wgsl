struct Vertex {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
}

@group(0) @binding(0) var framebuffer: texture_2d<f32>;

@vertex fn vertex_main(@builtin(vertex_index) index: u32) -> Vertex {
    var output: Vertex;
    output.uv = vec2<f32>(f32((index & 1u) * 2u), f32(index & 2u));
    output.position = vec4<f32>(output.uv * vec2<f32>(2.0, -2.0) + vec2<f32>(-1.0, 1.0), 0.0, 1.0);
    return output;
}

@fragment fn fragment_main(input: Vertex) -> @location(0) vec4<f32> {
    let size = textureDimensions(framebuffer);
    let texel = vec2<i32>(input.uv * vec2<f32>(size));
    return textureLoad(framebuffer, texel, 0);
}
