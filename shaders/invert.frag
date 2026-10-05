#version 440
// Dark pages: lightness is inverted, hues stay (a white page becomes near-black, black text near-white,
// a blue figure stays blue). Colors are premultiplied by alpha.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
};
layout(binding = 1) uniform sampler2D source;

void main()
{
    vec4 c = texture(source, qt_TexCoord0);
    float luma = dot(c.rgb, vec3(0.299, 0.587, 0.114));
    vec3 flipped = clamp(c.rgb + c.a - 2.0 * luma, 0.0, c.a);
    // Not pure black or white: easier on the eyes.
    fragColor = vec4(flipped * 0.86 + 0.07 * c.a, c.a) * qt_Opacity;
}
