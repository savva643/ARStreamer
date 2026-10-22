#include <metal_stdlib>
using namespace metal;

// Показ картинки лаунчера с ПК: доворот по гироскопу + (стерео) + линзы VR-очков + (фон — своя камера).
// Та же математика, что в эталоне SensorStream/tools/stream_simulator.cpp (ReturnClient::compose).

struct ReturnUniforms {
    float4x4 toRendered;   // луч экрана (оси экрана: x вправо, y вверх, z к зрителю) -> оси отрендеренного глаза
    float4x4 toCamera;     // луч экрана -> камера телефона (OpenCV: x вправо, y вниз, z вперёд)
    float4 rendered;       // tanX, tanY отрендеренного глаза; глаз в текстуре (1 моно / 2 SBS); альфа снизу (0/1)
    float4 display;        // tanX, tanY показа (моно/стерео); режим (1/2/3); есть кадр ПК (0/1)
    float4 camK;           // fx/w, fy/h, cx/w, cy/h камеры телефона; 0 — фона с камеры нет
    float4 lens;           // k1, k2, хроматизм, max tan
    float4 lensGeom;       // ширина экрана мм, высота мм, между линзами мм, экран->линза мм
    float4 viewport;       // сдвиг центра линз по y мм, ширина экрана px, высота px, высота цветной части в текстуре (доля)
    float4 color;          // кадр ПК: full range, BT.709; камера: full range, BT.709
};

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut returnVertex(uint vid [[vertex_id]]) {
    // Один треугольник на весь экран
    float2 p = float2((vid << 1) & 2, vid & 2);
    VertexOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

static float3 yuvToRgb(float y, float2 cbcr, bool fullRange, bool bt709) {
    if (!fullRange) {
        y = (y - 16.0 / 255.0) * (255.0 / 219.0);
        cbcr = (cbcr - 128.0 / 255.0) * (255.0 / 224.0);
    } else {
        cbcr -= 128.0 / 255.0;
    }
    float3 rgb;
    if (bt709) {
        rgb = float3(y + 1.5748 * cbcr.y, y - 0.1873 * cbcr.x - 0.4681 * cbcr.y, y + 1.8556 * cbcr.x);
    } else {
        rgb = float3(y + 1.402 * cbcr.y, y - 0.344136 * cbcr.x - 0.714136 * cbcr.y, y + 1.772 * cbcr.x);
    }
    return saturate(rgb);
}

// Кадр ПК по лучу экрана: premultiplied RGB + альфа (вне кадра — прозрачно)
static float4 sampleRendered(float3 s, int eye, constant ReturnUniforms& u,
                             texture2d<float> texY, texture2d<float> texUV, sampler smp) {
    if (u.display.w < 0.5) return float4(0.0);
    float3 r = (u.toRendered * float4(s, 0.0)).xyz;
    if (r.z > -1e-5) return float4(0.0);
    float2 t = r.xy / -r.z;
    float2 uv = float2(0.5 + 0.5 * t.x / u.rendered.x, 0.5 - 0.5 * t.y / u.rendered.y);
    if (any(uv < 0.0) || any(uv > 1.0)) return float4(0.0);
    float eyes = u.rendered.z;
    float2 tc = float2((uv.x + float(eye) * (eyes > 1.5 ? 1.0 : 0.0)) / eyes, uv.y);
    bool alpha = u.rendered.w > 0.5;
    if (alpha) {
        // Цвет — верхняя половина, альфа — яркость нижней (не даём фильтру залезть через шов)
        float h = float(texY.get_height());
        tc.y = clamp(tc.y * 0.5, 0.5 / h, 0.5 - 1.0 / h);
    }
    float y = texY.sample(smp, tc).r;
    float2 cbcr = texUV.sample(smp, tc).rg;
    float3 rgb = yuvToRgb(y, cbcr, u.color.x > 0.5, u.color.y > 0.5);
    float a = 1.0;
    if (alpha) {
        a = texY.sample(smp, float2(tc.x, tc.y + 0.5)).r;
        if (u.color.x < 0.5) a = saturate((a - 16.0 / 255.0) * (255.0 / 219.0));
    }
    return float4(rgb, a);
}

// Камера телефона по лучу экрана (фон)
static float3 sampleCamera(float3 s, constant ReturnUniforms& u, texture2d<float> camY, texture2d<float> camUV, sampler smp) {
    if (u.camK.x <= 0.0) return float3(0.0);
    float3 c = (u.toCamera * float4(s, 0.0)).xyz;
    if (c.z < 1e-5) return float3(0.0);
    float2 uv = float2(u.camK.x * c.x / c.z + u.camK.z, u.camK.y * c.y / c.z + u.camK.w);
    if (any(uv < 0.0) || any(uv > 1.0)) return float3(0.0);
    return yuvToRgb(camY.sample(smp, uv).r, camUV.sample(smp, uv).rg, u.color.z > 0.5, u.color.w > 0.5);
}

static float3 shade(float3 s, int eye, constant ReturnUniforms& u, texture2d<float> texY, texture2d<float> texUV,
                    texture2d<float> camY, texture2d<float> camUV, sampler smp) {
    float4 v = sampleRendered(s, eye, u, texY, texUV, smp);
    if (u.camK.x <= 0.0) return v.rgb;
    return v.rgb + sampleCamera(s, u, camY, camUV, smp) * (1.0 - v.a);   // кадр ПК — premultiplied
}

fragment float4 returnFragment(VertexOut in [[stage_in]],
                               constant ReturnUniforms& u [[buffer(0)]],
                               texture2d<float> texY [[texture(0)]],
                               texture2d<float> texUV [[texture(1)]],
                               texture2d<float> camY [[texture(2)]],
                               texture2d<float> camUV [[texture(3)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float2 px = in.position.xy;          // пиксели экрана, начало — левый верхний угол
    float W = u.viewport.y, H = u.viewport.z;
    int mode = int(u.display.z + 0.5);

    if (mode == 3) {
        // Линзы: точка экрана в мм -> tan относительно центра линзы своего глаза -> угол глаза (подушка линзы)
        float2 mm = px / float2(W, H) * u.lensGeom.xy;
        int eye = mm.x >= u.lensGeom.x * 0.5 ? 1 : 0;
        float cx = u.lensGeom.x * 0.5 + (eye == 0 ? -0.5 : 0.5) * u.lensGeom.z;
        float cy = u.lensGeom.y * 0.5 + u.viewport.x;
        float2 d = float2(mm.x - cx, -(mm.y - cy)) / u.lensGeom.w;
        float r2 = dot(d, d);
        float f = 1.0 + u.lens.x * r2 + u.lens.y * r2 * r2;
        float2 t = d * f;
        if (dot(t, t) > u.lens.w * u.lens.w) return float4(0.0, 0.0, 0.0, 1.0);
        // Хроматизм линзы: красный и синий — со своим масштабом
        float ca = u.lens.z;
        float r = shade(float3(t * (1.0 + ca), -1.0), eye, u, texY, texUV, camY, camUV, smp).r;
        float g = shade(float3(t, -1.0), eye, u, texY, texUV, camY, camUV, smp).g;
        float b = shade(float3(t * (1.0 - ca), -1.0), eye, u, texY, texUV, camY, camUV, smp).b;
        return float4(r, g, b, 1.0);
    }

    float ew = mode == 2 ? W * 0.5 : W;
    int eye = (mode == 2 && px.x >= ew) ? 1 : 0;
    float2 uv = float2((px.x - float(eye) * ew) / ew, px.y / H);
    float3 s = float3((2.0 * uv.x - 1.0) * u.display.x, (1.0 - 2.0 * uv.y) * u.display.y, -1.0);
    return float4(shade(s, eye, u, texY, texUV, camY, camUV, smp), 1.0);
}
