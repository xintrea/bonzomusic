#version 410 core

uniform float fGlobalTime;// in seconds
uniform vec2 v2Resolution;// viewport resolution (in pixels)
uniform float fFrameTime;// duration of the last frame, in seconds

uniform sampler1D texFFT;// towards 0.0 is bass / lower freq, towards 1.0 is higher / treble freq
uniform sampler1D texFFTSmoothed;// this one has longer falloff and less harsh transients
uniform sampler1D texFFTIntegrated;// this is continually increasing
uniform sampler2D texPreviousFrame;// screenshot of the previous frame

uniform sampler2D textureGrammophonePlate;


const float PI=3.1415926535897932384626433832795;

const int   RAY_MARCH_MAX_STEPS=100;
const float RAY_MARCH_MAX_DIST=100.0;
const float RAY_MARCH_SURF_DIST=0.001;

// const int MAXSAMPLES=4;


// ----------------
// Random generator
// ----------------

// A single iteration of Bob Jenkins' One-At-A-Time hashing algorithm.
uint hash(uint x){
    x+=(x<<10u);
    x^=(x>>6u);
    x+=(x<<3u);
    x^=(x>>11u);
    x+=(x<<15u);
    return x;
}

// Compound versions of the hashing algorithm I whipped together.
uint hash(uvec2 v){return hash(v.x^hash(v.y));}
uint hash(uvec3 v){return hash(v.x^hash(v.y)^hash(v.z));}
uint hash(uvec4 v){return hash(v.x^hash(v.y)^hash(v.z)^hash(v.w));}

// Construct a float with half-open range [0:1] using low 23 bits.
// All zeroes yields 0.0, all ones yields the next smallest representable value below 1.0.
float floatConstruct(uint m){
    const uint ieeeMantissa=0x007FFFFFu;// binary32 mantissa bitmask
    const uint ieeeOne=0x3F800000u;// 1.0 in IEEE binary32
    
    m&=ieeeMantissa;// Keep only mantissa bits (fractional part)
    m|=ieeeOne;// Add fractional part to 1.0
    
    float f=uintBitsToFloat(m);// Range [1:2]
    return f-1.;// Range [0:1]
}

// Pseudo-random value in half-open range [0:1].
float rand(float x){return floatConstruct(hash(floatBitsToUint(x+fGlobalTime)));}
float rand(vec2 v){return floatConstruct(hash(floatBitsToUint(v+fGlobalTime)));}
float rand(vec3 v){return floatConstruct(hash(floatBitsToUint(v+fGlobalTime)));}
float rand(vec4 v){return floatConstruct(hash(floatBitsToUint(v+fGlobalTime)));}


// -----------------------
// Basic 2D transformation
// -----------------------

const mat4 identityMatrix=mat4(vec4(1,0,0,0),vec4(0,1,0,0),vec4(0,0,1,0),vec4(0,0,0,1));

mat4 get2DTranslateMatrix(float x,float y)
{
    mat4 result=identityMatrix;
    result[3][0]=x;
    result[3][1]=y;
    return result;
}

mat4 get2DScaleMatrix(float x,float y)
{
    mat4 result=identityMatrix;
    result[0][0]=x;
    result[1][1]=y;
    return result;
}

mat4 get2DRotateMatrix(float a)
{
    mat4 result=identityMatrix;
    float sinA=sin(a);
    float cosA=cos(a);
    
    result[0][0]=cosA;
    result[0][1]=sinA;
    result[1][0]=-sinA;
    result[1][1]=cosA;
    return result;
}


// -------------
// SDF 3D figure
// -------------

float sdCylinder(vec3 p, float r, float height) 
{
    // Cylinder standing upright on the xz plane
	float d = length(p.xz) - r;
	d = max(d, clamp( abs(p.y) - height, 0, height )); // max( d, abs(p.y) - height )

	return d;
}


// -------------------
// Ray march functions
// -------------------

float GetDist(vec3 p) 
{
    float d = sdCylinder(p, 1.0, 0.05); // float d = sdBox(p, vec3(1));
    
    return d;
}


float RayMarch(vec3 ro, vec3 rd) {
	float dO=0.;
    
    for(int i=0; i<RAY_MARCH_MAX_STEPS; i++) 
    {
    	vec3 p = ro + rd*dO;
        float dS = GetDist(p);
        dO += dS;
        if(dO>RAY_MARCH_MAX_DIST || abs(dS)<RAY_MARCH_SURF_DIST)
        {
            break;
        }
    }
    
    return dO;
}

vec3 GetNormal(vec3 p) {
	float d = GetDist(p);
    vec2 e = vec2(.001, 0);
    
    vec3 n = d - vec3(
        GetDist(p-e.xyy),
        GetDist(p-e.yxy),
        GetDist(p-e.yyx));
    
    return normalize(n);
}

vec3 GetRayDir(vec2 uv, vec3 p, vec3 l, float z) {
    vec3 f = normalize(l-p),
        r = normalize(cross(vec3(0,1,0), f)),
        u = cross(f,r),
        c = f*z,
        i = c + uv.x*r + uv.y*u,
        d = normalize(i);
    return d;
}


// Calculate camera direction normalize vector
// ro - ray origin, point in 3D space of camera position
// target - point in 3D space of camera view to
// uv - current pixel coordinates
vec3 cameraDirection (vec3 ro, vec3 target, vec2 uv) {
    vec3 f = normalize(target-ro);
    vec3 l = normalize(cross(vec3(0.,1.,0.),f));
    vec3 u = normalize(cross(f,l));
    return normalize(f + l*uv.x + u*uv.y);
}


// ------------------
// Wave plate drawing
// ------------------

vec4 wavePlate(vec2 uvPixelPosition, float maxRadius, float waveLen, vec2 focusShift, float angle)
{
    // Center of plate and rotate center
    vec2 center=vec2(.2);
    
    // Rotate
    mat4 matPlateRotate=get2DTranslateMatrix(center.x, center.y)*
    get2DRotateMatrix(fGlobalTime)*
    inverse(get2DScaleMatrix(1,.5))*
    inverse(get2DTranslateMatrix(center.x, center.y));
    
    vec4 afterRotatePos=vec4(uvPixelPosition.x, uvPixelPosition.y,0,1);
    afterRotatePos=matPlateRotate*afterRotatePos;
    
    uvPixelPosition=vec2(afterRotatePos.x, afterRotatePos.y);
    
    // Small mix random by coordinats
    uvPixelPosition.x=uvPixelPosition.x+sin(rand(uvPixelPosition.x*uvPixelPosition.y))/500.0;
    uvPixelPosition.y=uvPixelPosition.y+cos(rand(uvPixelPosition.x/uvPixelPosition.y))/500.0;
    
    float len1=length(uvPixelPosition-center);
    
    if(len1>maxRadius)
    {
        return vec4(0.0, 0.0, 0.0, 0.0); // Transparent color
    }
    
    float c1=sin(len1/waveLen);
    
    float len2=length(uvPixelPosition+focusShift-center);
    float c2=sin(len2/waveLen);
    
    float c=(c1+c2)/4.0-0.1; // Sybstract for saturation control, best diapason  0.1...0.2
    
    // Small mix random by color
    // c=c-0.1+rand(uvPixelPosition.x*uvPixelPosition.y)/10;
    
    return vec4(c, c, c, 1.0);
}

vec4 layerWavePlate(vec2 uvPixelPosition)
{
    vec2 focusShift=vec2(sin(fGlobalTime)/650.0+1.0/650.0*4.0, 0.001);
    
    int maxNum=3;
    vec4 acc=vec4(vec3(0.0), 1.0); // Accumulator
    for(int num=0; num<maxNum; num++)
    {
        // todo: Try adding randVec to uvPixelPosition
        // vec2 randVec=vec2(sin(rand(fGlobalTime+num))/1000.0, sin(rand(fGlobalTime+num*num))/1000.0);
        acc+=wavePlate(uvPixelPosition, 0.4, 0.00061, focusShift, fGlobalTime);
    }
    
    return vec4(acc.rgb*(1.0/float(maxNum)), 1.0);
}


// -----------------
// Grammophone plate
// -----------------

mat2 simpleRot(float a) {
    float s=sin(a), c=cos(a);
    return mat2(c, -s, s, c);
}

vec4 layerGrammophonePlate(vec2 uvPixelPosition)
{
    uvPixelPosition+=vec2(-0.1, -0.2);

    float rCamRotate=2.5;
    float hCam=0.5;

    float x=sin(-fGlobalTime)*rCamRotate;
    float y=hCam;
    float z=cos(-fGlobalTime)*rCamRotate;

    vec3 ro = vec3(x, y, z);

    // ro.xz *= simpleRot(fGlobalTime); // ro = ( get2DRotateMatrix(fGlobalTime)*vec4(ro, 1.0) ).xyz;
    // vec3 rd = GetRayDir(uvPixelPosition, ro, vec3(0.0), 1.0);

    vec3 rd=cameraDirection(ro, vec3(0.), uvPixelPosition);
    vec3 color = vec3(0);
   
    float d = RayMarch(ro, rd);

    if(d < RAY_MARCH_MAX_DIST) 
    {
        vec3 p = ro + rd * d;
        vec3 normal = GetNormal(p);
        // vec3 reflect = reflect(rd, normal); // For reflect support

        // Start color for current point
        // float dif = dot(normal, normalize(vec3(1,2,3)))*.5+.5;
        // color = vec3(dif);
        color = vec3(0.5); // Start color for current point
        
        // Texturing plate, it detect by normal (0, 1, 0)
        vec2 uvPixelAtTexture=vec2(0.0);
        if( distance(abs(normal), vec3(0.0, 1.0, 0.0)) < 0.001 )
        {
            uvPixelAtTexture=vec2( sin(p.z), cos(p.x) );
        }
        else // Texturing round
        {
            uvPixelAtTexture=vec2( 1/atan(p.x, p.z)-1.0, p.y-1.0 ); // atan(p.z, p.x), p.y
        }
        
        // Mix texture color
        color*=texture2D(textureGrammophonePlate, uvPixelAtTexture).rgb;
        
    }
    
    color = pow(color, vec3(0.4545)); // Gamma correction
    
    return vec4(color, 1.0);
}


void main(void)
{
    // Translate XY coordinats to UV coordinats
    vec2 uvPixelPosition=vec2(gl_FragCoord.x/v2Resolution.x, gl_FragCoord.y/v2Resolution.y);
    uvPixelPosition/=vec2(v2Resolution.y/v2Resolution.x, 1.0);
    float sideFieldWidth=(v2Resolution.x-v2Resolution.y)/2.0; // Width in pixel
    float uvSideFieldWidth=(v2Resolution.y+sideFieldWidth)/v2Resolution.y-1.0;
    uvPixelPosition=uvPixelPosition-vec2(uvSideFieldWidth, 0.0);
    
    // Pixel color
    vec4 color  = vec4(vec3(0.0), 1.0);
    vec4 color1 = vec4(vec3(0.0), 1.0);
    vec4 color2 = vec4(vec3(0.0), 1.0);

    color1=layerGrammophonePlate(uvPixelPosition);
    color2=layerWavePlate(uvPixelPosition);
    
    color=color1+color2;

    gl_FragColor=color;
}
