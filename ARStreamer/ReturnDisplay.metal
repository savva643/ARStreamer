//
//  ReturnDisplay.metal
//  ARStreamer
//
//  Metal shader для обработки возвращаемого видео с ПК на iPhone
//  Реализует timewarp - доворот кадра по гироскопу телефона
//

#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Униформы для timewarp
struct TimewarpUniforms {
    float4x4 projection;
    float4x4 eyeFromDevice;
    float4x4 predFromRef;
    float2 eyeOffset;
    float tanX;
    float tanY;
};

vertex VertexOut timewarpVertex(VertexIn in [[stage_in]],
                                constant TimewarpUniforms& uniforms [[buffer(0)]]) {
    VertexOut out;
    
    // Позиция вершины в пространстве экрана
    out.position = float4(in.position, 0.0, 1.0);
    
    // UV координаты для текстуры
    out.texCoord = in.texCoord;
    
    return out;
}

fragment float4 timewarpFragment(VertexOut in [[stage_in]],
                                texture2d<float> videoTexture [[texture(0)]],
                                texture2d<float> alphaTexture [[texture(1)]],
                                constant TimewarpUniforms& uniforms [[buffer(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    // Чтение цвета из видео текстуры
    float4 color = videoTexture.sample(textureSampler, in.texCoord);
    
    // Если есть альфа-канал, применяем его
    if (alphaTexture.has_texture()) {
        float alpha = alphaTexture.sample(textureSampler, in.texCoord).r;
        color.a = alpha;
    }
    
    return color;
}

// Простой vertex shader без timewarp (для совместимости)
vertex VertexOut simpleVertex(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.texCoord = in.texCoord;
    return out;
}

// Простой fragment shader
fragment float4 simpleFragment(VertexOut in [[stage_in]],
                               texture2d<float> videoTexture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    return videoTexture.sample(textureSampler, in.texCoord);
}
