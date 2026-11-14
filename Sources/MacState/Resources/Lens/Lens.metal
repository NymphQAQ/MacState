// Adapted from design-systems / Lens (MIT), see LICENSE and README.md here.
#include <metal_stdlib>
using namespace metal;
struct Uniforms { float4 viewport; float4 sourceRect; float4 optics; float4 tone; };
struct Shape { float4 box; float4 clip; float4 parameters; };
struct Vertex { float4 position [[position]]; float2 pixel; uint instance [[flat]]; };
vertex Vertex lensVertex(uint v [[vertex_id]], uint i [[instance_id]],
                        constant Uniforms &u [[buffer(0)]], const device Shape *shapes [[buffer(1)]]) {
    const float2 corners[] = {float2(0,0),float2(1,0),float2(0,1),float2(0,1),float2(1,0),float2(1,1)};
    float2 p = shapes[i].clip.xy + corners[v] * shapes[i].clip.zw;
    return {float4(p.x/u.viewport.x*2-1,1-p.y/u.viewport.y*2,0,1),p,i};
}
float roundedBox(float2 p, float2 b, float r) {
    float2 q = abs(p)-b+r;
    return min(max(q.x,q.y),0.f)+length(max(q,0.f))-r;
}
float3 scene(texture2d<float> t, float2 p, constant Uniforms &u, bool root) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = p/u.viewport.xy;
    if(root) uv = u.sourceRect.xy+uv*u.sourceRect.zw;
    return t.sample(s,uv).rgb;
}
float3 blurred(texture2d<float> t, float2 p, float r, constant Uniforms &u, bool root) {
    float3 c = scene(t,p,u,root)*.24;
    c += (scene(t,p+float2(r,0),u,root)+scene(t,p-float2(r,0),u,root)
        +scene(t,p+float2(0,r),u,root)+scene(t,p-float2(0,r),u,root))*.12;
    c += (scene(t,p+float2(r,r)*.707,u,root)+scene(t,p-float2(r,r)*.707,u,root)
        +scene(t,p+float2(r,-r)*.707,u,root)+scene(t,p+float2(-r,r)*.707,u,root))*.07;
    return c;
}
fragment float4 lensFragment(Vertex in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                             const device Shape *shapes [[buffer(1)]], texture2d<float> source [[texture(0)]]) {
    Shape shape = shapes[in.instance];
    bool root = shape.parameters.y > .5;
    float2 center = shape.box.xy+shape.box.zw*.5, p = in.pixel-center, b = shape.box.zw*.5;
    float radius = min(shape.parameters.x,min(b.x,b.y));
    float d = roundedBox(p,b,radius);
    float aa = max(fwidth(d)*.7,.25);
    float mask = 1-smoothstep(-aa,aa,d);
    if(mask <= 0) discard_fragment();
    // Silhouette, normal and highlights all use the SAME rounded SDF.
    float e = .7;
    float2 n = normalize(float2(roundedBox(p+float2(e,0),b,radius)-roundedBox(p-float2(e,0),b,radius),
                               roundedBox(p+float2(0,e),b,radius)-roundedBox(p-float2(0,e),b,radius))+.00001);
    float edge = clamp(1+d/max(min(min(b.x,b.y)*.48,19.f),.5f),0.f,1.f);
    float2 normalXY = n*pow(edge,1.65)*.94+clamp(p/max(b,1.f),-1.f,1.f)*.045*(1-edge);
    float3 normal = float3(normalXY,sqrt(max(1-dot(normalXY,normalXY),.001f)));
    float refraction = u.optics.x;
    float3 ray = refract(float3(0,0,-1),normal,1.f/1.45f);
    float2 offset = ray.xy/max(-ray.z,.05f)*(18+refraction*57)*refraction-p*.016*refraction;
    float2 at = in.pixel+offset;
    // A Gaussian prepass handles broad frost; this kernel softens each lens.
    float3 c = blurred(source,at,root ? 0.f : u.optics.y,u,root);
    float2 split = n*pow(edge,2.8)*refraction*.65;
    c.r += (scene(source,at+split,u,root).r-scene(source,at,u,root).r)*.8;
    c.b += (scene(source,at-split,u,root).b-scene(source,at,u,root).b)*.8;
    float luma = dot(c,float3(.2126,.7152,.0722));
    c = mix(float3(luma),c,1.035);
    float3 tint = mix(float3(.97,.985,1),float3(.10,.13,.17),u.tone.x);
    // Root applies density once; nested controls keep their own quiet tint.
    c = mix(c,tint,root ? u.optics.w : .035+(1-u.optics.z)*.08);
    float2 light = normalize(float2(-.55,-.85));
    float directional = pow(max(dot(n,light),0.f),7.f);
    float opposite = pow(max(dot(n,-light),0.f),7.f)*.52;
    float fresnel = .04+.96*pow(1-normal.z,5.f);
    float outline = 1-smoothstep(.12,1.1,abs(d+.65));
    float spec = (directional+opposite)*pow(edge,4.f)*.065
               +outline*(.018+directional*.35+opposite*.15)+fresnel*.035;
    c += spec*u.optics.z;
    c += exp(-pow((d+3)/1.65,2.f))*opposite*.038*u.optics.z;
    // Frost still has a soft rim, but NO refractive offset/specular caustic at 0%.
    c += outline*.018*(1-u.optics.z);
    // Premultiplied alpha. No rectangular shadow quad outside the SDF.
    return float4(c*mask,mask);
}
fragment float4 copyFragment(Vertex in [[stage_in]], constant Uniforms &u [[buffer(0)]], texture2d<float> source [[texture(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    return source.sample(s,in.pixel/u.viewport.xy);
}
