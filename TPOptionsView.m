//
//  TPOptionsView.m
//  teleport
//
//  Created by Julien Robert on 16/01/09.
//  Copyright 2009 Apple. All rights reserved.
//

#import "TPOptionsView.h"
#import "TPBezierPath.h"
#import "TPRemoteHost.h"

@implementation TPOptionsView

- (instancetype)initWithFrame:(NSRect)frameRect
{
	self = [super initWithFrame:frameRect];
	
#if 0
	if ([self respondsToSelector:@selector(setAppearance:)]) {
		[self setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameLightContent]];
	}
#endif
	
	NSShadow * shadow = [[NSShadow alloc] init];
	[shadow setShadowBlurRadius:2.0];
	[shadow setShadowColor:[NSColor colorWithCalibratedWhite:0.0 alpha:0.5]];
	[shadow setShadowOffset:NSMakeSize(0.0, -2.0)];
	[self setShadow:shadow];
	
	return self;
}

- (void)drawRect:(NSRect)rect
{
	CGContextRef ctx = [[NSGraphicsContext currentContext] graphicsPort];
	
	[[NSColor textBackgroundColor] set];
	NSRectFill([self bounds]);
	
	CGRect strokeRect = NSRectToCGRect(NSInsetRect([self bounds], 0.5, 0.5));
	CGContextSetLineWidth(ctx, 1.0);
	
	CGContextSetGrayStrokeColor(ctx, 0.7, 1.0);
	CGContextStrokeRect(ctx, strokeRect);
	
	strokeRect = CGRectInset(strokeRect, 1.0, 1.0);
	CGContextSetGrayStrokeColor(ctx, 1.0, 1.0);
	CGContextStrokeRect(ctx, strokeRect);
}

- (BOOL)acceptsFirstResponder
{
	return YES;
}

@end
